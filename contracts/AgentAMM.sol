// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgentAMM
 * @notice Constant-product AMM (x*y=k, 0.3% fee) for one agent's shares against the quote
 *         token (USDC). Post-graduation continuous market for Product A.
 *
 * Security-hardened vs the initial draft (audit fixes):
 *  - **Explicit reserves** (not balanceOf): swaps/liquidity update `shareReserve`/`quoteReserve`
 *    by tracked deltas, so donating tokens to this contract can no longer move the price or
 *    enable a first-depositor inflation attack.
 *  - **Optimal addLiquidity**: only the matched pair is pulled (Uniswap-V2 style); no silent
 *    donation of the over-supplied side.
 *  - **Deadlines** on every state-changing op to bound MEV/held-tx execution.
 *  - MIN_LIQUIDITY permanently locked on first mint.
 *
 * The quote token MUST be a standard, non-fee-on-transfer, non-rebasing ERC20 (USDC). The
 * launchpad owner vets it; fee-on-transfer tokens would desync tracked reserves from balances.
 */
contract AgentAMM is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable shareToken;
    IERC20 public immutable quoteToken;

    uint256 public shareReserve;
    uint256 public quoteReserve;
    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidityBalance;

    uint256 private constant FEE_NUM = 997; // 0.3% fee
    uint256 private constant FEE_DEN = 1000;
    uint256 private constant MIN_LIQUIDITY = 1000; // locked forever on first mint

    event LiquidityAdded(address indexed provider, uint256 shareAmount, uint256 quoteAmount, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 shareAmount, uint256 quoteAmount, uint256 liquidity);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut);

    modifier ensure(uint256 deadline) {
        require(block.timestamp <= deadline, "expired");
        _;
    }

    constructor(address _shareToken, address _quoteToken) {
        require(_shareToken != address(0) && _quoteToken != address(0), "zero addr");
        require(_shareToken != _quoteToken, "same token");
        shareToken = IERC20(_shareToken);
        quoteToken = IERC20(_quoteToken);
    }

    // ─── Liquidity ────────────────────────────────────────────────────────────

    /**
     * @notice Add liquidity. Approve both tokens. `*Desired` are maximums; the contract pulls
     *         only the matched pair. `*Min` guard the ratio against front-running.
     */
    function addLiquidity(
        uint256 shareDesired,
        uint256 quoteDesired,
        uint256 shareMin,
        uint256 quoteMin,
        uint256 deadline
    ) external ensure(deadline) nonReentrant returns (uint256 liquidity, uint256 shareUsed, uint256 quoteUsed) {
        require(shareDesired > 0 && quoteDesired > 0, "amounts>0");

        if (totalLiquidity == 0) {
            (shareUsed, quoteUsed) = (shareDesired, quoteDesired);
            liquidity = _sqrt(shareUsed * quoteUsed);
            require(liquidity > MIN_LIQUIDITY, "insufficient initial");
            liquidity -= MIN_LIQUIDITY;
            totalLiquidity += MIN_LIQUIDITY; // permanent lock
        } else {
            uint256 quoteOptimal = (shareDesired * quoteReserve) / shareReserve;
            if (quoteOptimal <= quoteDesired) {
                require(quoteOptimal >= quoteMin, "quote slippage");
                (shareUsed, quoteUsed) = (shareDesired, quoteOptimal);
            } else {
                uint256 shareOptimal = (quoteDesired * shareReserve) / quoteReserve;
                require(shareOptimal <= shareDesired && shareOptimal >= shareMin, "share slippage");
                (shareUsed, quoteUsed) = (shareOptimal, quoteDesired);
            }
            uint256 lShare = (shareUsed * totalLiquidity) / shareReserve;
            uint256 lQuote = (quoteUsed * totalLiquidity) / quoteReserve;
            liquidity = lShare < lQuote ? lShare : lQuote;
        }
        require(liquidity > 0, "no liquidity minted");

        shareToken.safeTransferFrom(msg.sender, address(this), shareUsed);
        quoteToken.safeTransferFrom(msg.sender, address(this), quoteUsed);

        shareReserve += shareUsed;
        quoteReserve += quoteUsed;
        liquidityBalance[msg.sender] += liquidity;
        totalLiquidity += liquidity;

        emit LiquidityAdded(msg.sender, shareUsed, quoteUsed, liquidity);
    }

    /// @notice Remove liquidity proportionally.
    function removeLiquidity(uint256 liquidity, uint256 shareMin, uint256 quoteMin, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        returns (uint256 shareAmount, uint256 quoteAmount)
    {
        require(liquidity > 0 && liquidityBalance[msg.sender] >= liquidity, "bad liquidity");

        shareAmount = (liquidity * shareReserve) / totalLiquidity;
        quoteAmount = (liquidity * quoteReserve) / totalLiquidity;
        require(shareAmount >= shareMin && quoteAmount >= quoteMin, "slippage");
        require(shareAmount > 0 && quoteAmount > 0, "insufficient reserves");

        liquidityBalance[msg.sender] -= liquidity;
        totalLiquidity -= liquidity;
        shareReserve -= shareAmount;
        quoteReserve -= quoteAmount;

        shareToken.safeTransfer(msg.sender, shareAmount);
        quoteToken.safeTransfer(msg.sender, quoteAmount);

        emit LiquidityRemoved(msg.sender, shareAmount, quoteAmount, liquidity);
    }

    // ─── Swaps ────────────────────────────────────────────────────────────────

    function swapShareForQuote(uint256 shareIn, uint256 minQuoteOut, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        returns (uint256 quoteOut)
    {
        require(shareIn > 0, "in>0");
        quoteOut = _getAmountOut(shareIn, shareReserve, quoteReserve);
        require(quoteOut >= minQuoteOut && quoteOut > 0, "slippage");

        shareToken.safeTransferFrom(msg.sender, address(this), shareIn);
        shareReserve += shareIn;
        quoteReserve -= quoteOut;
        quoteToken.safeTransfer(msg.sender, quoteOut);

        emit Swap(msg.sender, address(shareToken), shareIn, quoteOut);
    }

    function swapQuoteForShare(uint256 quoteIn, uint256 minShareOut, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        returns (uint256 shareOut)
    {
        require(quoteIn > 0, "in>0");
        shareOut = _getAmountOut(quoteIn, quoteReserve, shareReserve);
        require(shareOut >= minShareOut && shareOut > 0, "slippage");

        quoteToken.safeTransferFrom(msg.sender, address(this), quoteIn);
        quoteReserve += quoteIn;
        shareReserve -= shareOut;
        shareToken.safeTransfer(msg.sender, shareOut);

        emit Swap(msg.sender, address(quoteToken), quoteIn, shareOut);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return _getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function quoteForShare(uint256 shareIn) external view returns (uint256) {
        return _getAmountOut(shareIn, shareReserve, quoteReserve);
    }

    function shareForQuote(uint256 quoteIn) external view returns (uint256) {
        return _getAmountOut(quoteIn, quoteReserve, shareReserve);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        require(reserveIn > 0 && reserveOut > 0, "no liquidity");
        uint256 amountInWithFee = amountIn * FEE_NUM;
        return (amountInWithFee * reserveOut) / ((reserveIn * FEE_DEN) + amountInWithFee);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
