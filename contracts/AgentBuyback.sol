// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAgentAMM.sol";

/**
 * @title AgentBuyback
 * @notice The buyback leg of the tokenomics loop (see docs/TOKENOMICS.md). It is funded in USDC
 *         from a **mix of real x402 asset revenue and curve/AMM trading fees**, market-buys the
 *         agent token **A** on the agent's AMM, and sends the A to the **treasury**, where it is
 *         permanently retired (the treasury has no path to sell A).
 *
 *         **Execution is TWAP / batched, not a single naive market buy.** A naive buy is
 *         front-runnable (MEV) and moves the price against itself. Instead a keeper (the dobx
 *         cron) calls {executeBuyback} in small tranches, throttled by:
 *           - `maxSpendPerEpoch` over `epochLength` — an average-rate ceiling per rolling window;
 *           - `minInterval` between buys — forces the window budget to be spread, not drained in
 *             one block.
 *         Slippage is bounded per tranche via `minAOut`. This spreads accumulation over time
 *         (a discrete TWAP) and blunts sandwiching.
 */
contract AgentBuyback is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable agentToken; // A — bought and sent to treasury
    IERC20 public immutable quoteToken; // USDC — buyback funds
    IAgentAMM public immutable amm;
    address public immutable treasury;

    address public keeper;              // allowed to execute tranches (the dobx cron)

    uint256 public maxSpendPerEpoch;    // USDC ceiling per rolling epoch
    uint256 public epochLength;         // seconds per epoch
    uint256 public minInterval;         // min seconds between tranches

    uint256 public epochStart;          // start of the current epoch
    uint256 public spentThisEpoch;      // USDC spent in the current epoch
    uint256 public lastBuyTime;         // timestamp of the last tranche

    event Funded(address indexed from, uint256 amount);
    event BuybackExecuted(uint256 quoteSpent, uint256 aBought, uint256 spentThisEpoch);
    event KeeperUpdated(address indexed keeper);
    event ThrottleUpdated(uint256 maxSpendPerEpoch, uint256 epochLength, uint256 minInterval);

    modifier onlyKeeperOrOwner() {
        require(msg.sender == keeper || msg.sender == owner(), "not keeper");
        _;
    }

    constructor(
        address _amm,
        address _treasury,
        address _owner,
        uint256 _maxSpendPerEpoch,
        uint256 _epochLength,
        uint256 _minInterval
    ) Ownable(_owner) {
        require(_amm != address(0) && _treasury != address(0), "zero addr");
        require(_maxSpendPerEpoch > 0 && _epochLength > 0, "bad throttle");
        amm = IAgentAMM(_amm);
        agentToken = IERC20(IAgentAMM(_amm).shareToken());
        quoteToken = IERC20(IAgentAMM(_amm).quoteToken());
        treasury = _treasury;
        maxSpendPerEpoch = _maxSpendPerEpoch;
        epochLength = _epochLength;
        minInterval = _minInterval;
        epochStart = block.timestamp;
    }

    // ─── Config ─────────────────────────────────────────────────────────────────

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function setThrottle(uint256 _maxSpendPerEpoch, uint256 _epochLength, uint256 _minInterval)
        external
        onlyOwner
    {
        require(_maxSpendPerEpoch > 0 && _epochLength > 0, "bad throttle");
        maxSpendPerEpoch = _maxSpendPerEpoch;
        epochLength = _epochLength;
        minInterval = _minInterval;
        emit ThrottleUpdated(_maxSpendPerEpoch, _epochLength, _minInterval);
    }

    // ─── Funding ────────────────────────────────────────────────────────────────

    /// @notice Deposit USDC buyback funds (revenue router / trading-fee sweep). Approve first.
    function deposit(uint256 amount) external {
        require(amount > 0, "amount>0");
        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    function funds() external view returns (uint256) {
        return quoteToken.balanceOf(address(this));
    }

    /// @notice USDC still spendable in the current (or freshly rolled) epoch.
    function epochBudgetRemaining() public view returns (uint256) {
        if (block.timestamp >= epochStart + epochLength) return maxSpendPerEpoch;
        return maxSpendPerEpoch > spentThisEpoch ? maxSpendPerEpoch - spentThisEpoch : 0;
    }

    // ─── Execution (TWAP tranche) ───────────────────────────────────────────────

    /**
     * @notice Execute one buyback tranche: spend `quoteAmount` USDC on A and send the A to the
     *         treasury. Throttled by the epoch budget and the min interval.
     * @param quoteAmount USDC to spend this tranche
     * @param minAOut     minimum A out (per-tranche slippage guard)
     * @param deadline    AMM/tx deadline
     */
    function executeBuyback(uint256 quoteAmount, uint256 minAOut, uint256 deadline)
        external
        onlyKeeperOrOwner
        nonReentrant
        returns (uint256 aBought)
    {
        require(quoteAmount > 0, "amount>0");
        require(quoteAmount <= quoteToken.balanceOf(address(this)), "insufficient funds");
        require(block.timestamp >= lastBuyTime + minInterval, "too soon");

        // Roll the epoch if it has elapsed.
        if (block.timestamp >= epochStart + epochLength) {
            epochStart = block.timestamp;
            spentThisEpoch = 0;
        }
        require(spentThisEpoch + quoteAmount <= maxSpendPerEpoch, "epoch cap");

        spentThisEpoch += quoteAmount;
        lastBuyTime = block.timestamp;

        quoteToken.forceApprove(address(amm), quoteAmount);
        aBought = amm.swapQuoteForShare(quoteAmount, minAOut, deadline);

        // Retire the bought A in the treasury (non-sellable sink).
        agentToken.safeTransfer(treasury, aBought);

        emit BuybackExecuted(quoteAmount, aBought, spentThisEpoch);
    }
}
