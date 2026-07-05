// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgentAMM
 * @notice Constant-product AMM (x*y=k, 0.3% fee) for one agent's shares against the quote
 *         token (USDC). Adapted from DOBI's DobiSwap, but both sides are ERC20 (no native
 *         coin) so it settles in real USDC.
 *
 * This is the continuous secondary market a launch graduates into: after the bonding curve
 * hits its graduation target, the curve seeds this pool with the remaining share inventory
 * plus the USDC it raised, and locks the LP. From then on price is discovered here.
 *
 * LP accounting is internal (a balance mapping), matching the DobiSwap prototype.
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
    uint256 private constant MIN_LIQUIDITY = 1000; // locked forever on first mint (dust guard)

    event LiquidityAdded(address indexed provider, uint256 shareAmount, uint256 quoteAmount, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 shareAmount, uint256 quoteAmount, uint256 liquidity);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address _shareToken, address _quoteToken) {
        require(_shareToken != address(0) && _quoteToken != address(0), "zero addr");
        require(_shareToken != _quoteToken, "same token");
        shareToken = IERC20(_shareToken);
        quoteToken = IERC20(_quoteToken);
    }

    // ─── Liquidity ────────────────────────────────────────────────────────────

    /**
     * @notice Add liquidity. Caller must approve both tokens first. On the first add the
     *         initial ratio sets the price; later adds must match the current ratio (excess
     *         is not pulled — pass balanced amounts).
     */
    function addLiquidity(uint256 shareAmount, uint256 quoteAmount)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        require(shareAmount > 0 && quoteAmount > 0, "amounts>0");

        if (totalLiquidity == 0) {
            liquidity = _sqrt(shareAmount * quoteAmount);
            require(liquidity > MIN_LIQUIDITY, "insufficient initial");
            // permanently lock MIN_LIQUIDITY so totalLiquidity can never return to 0
            liquidity -= MIN_LIQUIDITY;
            totalLiquidity += MIN_LIQUIDITY;
        } else {
            uint256 lShare = (shareAmount * totalLiquidity) / shareReserve;
            uint256 lQuote = (quoteAmount * totalLiquidity) / quoteReserve;
            liquidity = lShare < lQuote ? lShare : lQuote;
        }
        require(liquidity > 0, "no liquidity minted");

        shareToken.safeTransferFrom(msg.sender, address(this), shareAmount);
        quoteToken.safeTransferFrom(msg.sender, address(this), quoteAmount);

        liquidityBalance[msg.sender] += liquidity;
        totalLiquidity += liquidity;
        _sync();

        emit LiquidityAdded(msg.sender, shareAmount, quoteAmount, liquidity);
    }

    /// @notice Remove liquidity proportionally.
    function removeLiquidity(uint256 liquidity)
        external
        nonReentrant
        returns (uint256 shareAmount, uint256 quoteAmount)
    {
        require(liquidity > 0, "liquidity>0");
        require(liquidityBalance[msg.sender] >= liquidity, "insufficient LP");

        shareAmount = (liquidity * shareReserve) / totalLiquidity;
        quoteAmount = (liquidity * quoteReserve) / totalLiquidity;
        require(shareAmount > 0 && quoteAmount > 0, "insufficient reserves");

        liquidityBalance[msg.sender] -= liquidity;
        totalLiquidity -= liquidity;

        shareToken.safeTransfer(msg.sender, shareAmount);
        quoteToken.safeTransfer(msg.sender, quoteAmount);
        _sync();

        emit LiquidityRemoved(msg.sender, shareAmount, quoteAmount, liquidity);
    }

    // ─── Swaps ────────────────────────────────────────────────────────────────

    /// @notice Swap agent shares for quote (USDC). Approve shares first.
    function swapShareForQuote(uint256 shareIn, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        require(shareIn > 0, "in>0");
        quoteOut = _getAmountOut(shareIn, shareReserve, quoteReserve);
        require(quoteOut >= minQuoteOut, "slippage");

        shareToken.safeTransferFrom(msg.sender, address(this), shareIn);
        quoteToken.safeTransfer(msg.sender, quoteOut);
        _sync();

        emit Swap(msg.sender, address(shareToken), shareIn, quoteOut);
    }

    /// @notice Swap quote (USDC) for agent shares. Approve quote first.
    function swapQuoteForShare(uint256 quoteIn, uint256 minShareOut)
        external
        nonReentrant
        returns (uint256 shareOut)
    {
        require(quoteIn > 0, "in>0");
        shareOut = _getAmountOut(quoteIn, quoteReserve, shareReserve);
        require(shareOut >= minShareOut, "slippage");

        quoteToken.safeTransferFrom(msg.sender, address(this), quoteIn);
        shareToken.safeTransfer(msg.sender, shareOut);
        _sync();

        emit Swap(msg.sender, address(quoteToken), quoteIn, shareOut);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256)
    {
        return _getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function quoteForShare(uint256 shareIn) external view returns (uint256) {
        return _getAmountOut(shareIn, shareReserve, quoteReserve);
    }

    function shareForQuote(uint256 quoteIn) external view returns (uint256) {
        return _getAmountOut(quoteIn, quoteReserve, shareReserve);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        require(reserveIn > 0 && reserveOut > 0, "no liquidity");
        uint256 amountInWithFee = amountIn * FEE_NUM;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DEN) + amountInWithFee;
        return numerator / denominator;
    }

    /// @dev Sync cached reserves to actual balances (defends against fee-on-transfer drift).
    function _sync() internal {
        shareReserve = shareToken.balanceOf(address(this));
        quoteReserve = quoteToken.balanceOf(address(this));
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
