// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./AgentAMM.sol";

/**
 * @title AgentBondingCurve
 * @notice Fair-launch bonding curve for one agent's shares, priced in USDC. Adapted from
 *         DOBI's DobiPump, but the curve is denominated per WHOLE share so it works with a
 *         6-decimal quote (USDC) against an 18-decimal share token without precision loss.
 *
 *   pricePerWholeShare(i) = basePrice + i * slope      (i = whole shares already sold)
 *   cost(k) = sum of the next k prices = k*basePrice + slope*(2*sold + k - 1)*k/2
 *
 * `basePrice`/`slope` are in USDC base units per whole share (e.g. basePrice 50_000 = $0.05).
 *
 * When USDC raised reaches `graduationRaise`, the curve GRADUATES: deploys an {AgentAMM},
 * seeds it with the leftover share inventory + the USDC collected, and permanently locks the
 * LP (the curve holds it and exposes no withdrawal). After that, trading is on the AMM only.
 */
contract AgentBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18; // base units per whole share

    IERC20 public immutable shareToken;
    IERC20 public immutable quoteToken; // USDC

    uint256 public immutable basePrice;       // USDC base units per whole share at sold=0
    uint256 public immutable slope;           // USDC base units added per whole share sold
    uint256 public immutable sellFeeBps;      // retained by the pool on sells
    uint256 public immutable buyFeeBps;       // taken to feeRecipient on buys
    uint256 public immutable graduationRaise; // USDC (net) that triggers graduation
    address public immutable feeRecipient;

    uint256 public sold;    // WHOLE shares sold to buyers
    uint256 public raised;  // net USDC held by the curve (seeds the AMM at graduation)
    bool public graduated;
    AgentAMM public amm;

    event Bought(address indexed buyer, uint256 wholeShares, uint256 cost, uint256 fee, uint256 newPrice);
    event Sold(address indexed seller, uint256 wholeShares, uint256 proceeds, uint256 newPrice);
    event Graduated(address indexed amm, uint256 shareLiquidity, uint256 quoteLiquidity);

    constructor(
        address _shareToken,
        address _quoteToken,
        uint256 _basePrice,
        uint256 _slope,
        uint256 _sellFeeBps,
        uint256 _buyFeeBps,
        uint256 _graduationRaise,
        address _feeRecipient
    ) {
        require(_shareToken != address(0) && _quoteToken != address(0), "zero addr");
        require(_basePrice > 0, "basePrice>0");
        require(_graduationRaise > 0, "grad>0");
        require(_feeRecipient != address(0), "feeRecipient=0");
        require(_sellFeeBps <= 2000 && _buyFeeBps <= 2000, "fee too high");
        shareToken = IERC20(_shareToken);
        quoteToken = IERC20(_quoteToken);
        basePrice = _basePrice;
        slope = _slope;
        sellFeeBps = _sellFeeBps;
        buyFeeBps = _buyFeeBps;
        graduationRaise = _graduationRaise;
        feeRecipient = _feeRecipient;
    }

    // ─── Trading ──────────────────────────────────────────────────────────────

    /**
     * @notice Buy `wholeShares` agent shares. Caller must approve `maxQuoteCost` USDC.
     *         Total paid = curve cost + buy fee; the fee goes to `feeRecipient`.
     */
    function buy(uint256 wholeShares, uint256 maxQuoteCost) external nonReentrant {
        require(!graduated, "graduated");
        require(wholeShares > 0, "amount>0");
        uint256 baseAmount = wholeShares * SHARE_UNIT;
        require(baseAmount <= shareToken.balanceOf(address(this)), "not enough inventory");

        uint256 cost = getBuyCost(wholeShares);
        uint256 fee = (cost * buyFeeBps) / 10000;
        uint256 total = cost + fee;
        require(total > 0, "zero cost");
        require(total <= maxQuoteCost, "slippage");

        // effects
        sold += wholeShares;
        raised += cost;

        // interactions
        quoteToken.safeTransferFrom(msg.sender, address(this), total);
        if (fee > 0) quoteToken.safeTransfer(feeRecipient, fee);
        shareToken.safeTransfer(msg.sender, baseAmount);

        emit Bought(msg.sender, wholeShares, cost, fee, getCurrentPrice());

        if (raised >= graduationRaise) _graduate();
    }

    /**
     * @notice Sell `wholeShares` back to the curve before graduation. Approve the shares.
     *         Proceeds are net of the sell fee.
     */
    function sell(uint256 wholeShares, uint256 minQuoteOut) external nonReentrant {
        require(!graduated, "graduated");
        require(wholeShares > 0 && wholeShares <= sold, "bad amount");

        uint256 proceeds = getSellProceeds(wholeShares);
        require(proceeds >= minQuoteOut, "slippage");
        require(proceeds <= raised, "insufficient reserve");

        // effects
        sold -= wholeShares;
        raised -= proceeds;

        // interactions
        shareToken.safeTransferFrom(msg.sender, address(this), wholeShares * SHARE_UNIT);
        quoteToken.safeTransfer(msg.sender, proceeds);

        emit Sold(msg.sender, wholeShares, proceeds, getCurrentPrice());
    }

    // ─── Graduation ───────────────────────────────────────────────────────────

    function _graduate() internal {
        graduated = true;

        uint256 remainingShares = shareToken.balanceOf(address(this));
        uint256 quoteLiquidity = raised;
        require(remainingShares > 0 && quoteLiquidity > 0, "nothing to seed");

        AgentAMM pool = new AgentAMM(address(shareToken), address(quoteToken));
        amm = pool;

        shareToken.forceApprove(address(pool), remainingShares);
        quoteToken.forceApprove(address(pool), quoteLiquidity);
        // LP is minted to this curve and never withdrawable → liquidity locked forever.
        pool.addLiquidity(remainingShares, quoteLiquidity);

        emit Graduated(address(pool), remainingShares, quoteLiquidity);
    }

    // ─── Pricing (per whole share, exact integer arithmetic) ───────────────────

    /// @notice USDC price of the next whole share.
    function getCurrentPrice() public view returns (uint256) {
        return basePrice + (sold * slope);
    }

    /// @notice USDC cost to buy the next `k` whole shares.
    function getBuyCost(uint256 k) public view returns (uint256) {
        // sum_{i=sold}^{sold+k-1} (basePrice + i*slope)
        //   = k*basePrice + slope * (2*sold + k - 1) * k / 2
        return k * basePrice + (slope * (2 * sold + k - 1) * k) / 2;
    }

    /// @notice USDC returned for selling the last `k` whole shares (gross minus sell fee).
    function getSellProceeds(uint256 k) public view returns (uint256) {
        require(k <= sold, "exceeds sold");
        // sum_{i=sold-k}^{sold-1} (basePrice + i*slope)
        //   = k*basePrice + slope * (2*(sold-k) + k - 1) * k / 2
        uint256 gross = k * basePrice + (slope * (2 * (sold - k) + k - 1) * k) / 2;
        uint256 fee = (gross * sellFeeBps) / 10000;
        return gross - fee;
    }

    /// @notice Whole shares still available to buy on the curve.
    function inventory() external view returns (uint256) {
        return shareToken.balanceOf(address(this)) / SHARE_UNIT;
    }
}
