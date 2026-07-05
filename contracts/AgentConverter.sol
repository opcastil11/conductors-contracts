// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAgentAMM.sol";

/**
 * @title AgentConverter
 * @notice Step 1 of the A→B "convert" product (see docs/TOKENOMICS.md). Replaces the earlier
 *         oracle-anchored `AgentConversion`: there is **no NAV oracle**. Because DobProtocol
 *         pools distribute and trade in **USDC**, converting from the growth token A to the
 *         income token B is simply *sell A for USDC, then buy B with USDC*.
 *
 *         This contract does the atomic, on-chain half — **sell A for USDC on the agent's AMM
 *         and skim the convert fee to the treasury** — and returns the net USDC to the user. The
 *         user (or the dApp on their behalf) then buys B on the DobProtocol marketplace as step 2
 *         (the marketplace is listing-based, not an AMM, so the two halves cannot be one atomic
 *         tx; the treasury lists its B reserve as backstop liquidity so B is always available).
 *
 *         Selling A directly on the AMM is always possible and fee-free; this fee is the price of
 *         the convenience "convert" product and funds the treasury.
 */
contract AgentConverter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable agentToken; // A
    IERC20 public immutable quoteToken; // USDC
    IAgentAMM public immutable amm;
    address public immutable treasury;

    uint16 public feeBps;                       // convert fee on the USDC proceeds
    uint16 public constant MAX_FEE_BPS = 200;   // hard cap 2%

    event Converted(address indexed user, uint256 aIn, uint256 grossQuote, uint256 fee, uint256 netQuote);
    event FeeUpdated(uint16 feeBps);

    constructor(
        address _amm,
        address _treasury,
        uint16 _feeBps,
        address _owner
    ) Ownable(_owner) {
        require(_amm != address(0) && _treasury != address(0), "zero addr");
        require(_feeBps <= MAX_FEE_BPS, "fee too high");
        amm = IAgentAMM(_amm);
        agentToken = IERC20(IAgentAMM(_amm).shareToken());
        quoteToken = IERC20(IAgentAMM(_amm).quoteToken());
        treasury = _treasury;
        feeBps = _feeBps;
    }

    /// @notice Update the convert fee (bounded by MAX_FEE_BPS). Disclosed per agent.
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /**
     * @notice Sell `aIn` of A for USDC on the AMM, take the convert fee to the treasury, and send
     *         the net USDC to the caller. Approve A to this contract first.
     * @param aIn             amount of A to convert
     * @param minNetQuoteOut  minimum net USDC the caller will accept (slippage + fee protection)
     * @param deadline        AMM/tx deadline
     * @return netQuote       USDC returned to the caller (gross − fee)
     */
    function convert(uint256 aIn, uint256 minNetQuoteOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 netQuote)
    {
        require(aIn > 0, "aIn>0");

        agentToken.safeTransferFrom(msg.sender, address(this), aIn);
        agentToken.forceApprove(address(amm), aIn);

        // Sell all A for USDC; the min is enforced on the net below so the whole convert is atomic.
        uint256 grossQuote = amm.swapShareForQuote(aIn, 0, deadline);

        uint256 fee = (grossQuote * feeBps) / 10_000;
        netQuote = grossQuote - fee;
        require(netQuote >= minNetQuoteOut, "slippage");

        if (fee > 0) quoteToken.safeTransfer(treasury, fee);
        quoteToken.safeTransfer(msg.sender, netQuote);

        emit Converted(msg.sender, aIn, grossQuote, fee, netQuote);
    }

    /// @notice Preview the net USDC for converting `aIn`, given an AMM gross quote.
    function feeOn(uint256 grossQuote) external view returns (uint256 fee, uint256 net) {
        fee = (grossQuote * feeBps) / 10_000;
        net = grossQuote - fee;
    }
}
