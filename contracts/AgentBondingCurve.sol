// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./AgentAMM.sol";
import "./AgentShareToken.sol";

/**
 * @title AgentBondingCurve
 * @notice Fair-launch bonding curve for one agent's shares (Product A), priced per WHOLE share
 *         in the platform quote token (DOBX). Linear: price(i) = basePrice + i*slope; cost = the
 *         exact integral.
 *
 * Security-hardened vs the initial draft (audit fixes):
 *  - **No graduation price cliff**: the AMM is seeded at ~the curve's terminal price
 *    (`seedShares = raised / terminalPrice`), not by dumping the whole inventory. Leftover
 *    inventory goes to the treasury, so a back-runner can't buy the float far below what curve
 *    buyers paid.
 *  - **Donation-proof inventory**: remaining shares are computed from an immutable `curveSupply`
 *    minus `sold`/`burned`, never `balanceOf`, so donating shares can't skew the seed.
 *  - **Deadlines** on buy/sell to bound MEV/held-tx execution.
 *  - Fee ceiling tightened; graduation-config sanity is enforced by the launchpad.
 *
 * ─── The reserve is a LIABILITY, and conversion is what frees it (TOKENOMICS-V2 §4) ──────────
 *
 * `raised` is not proceeds the operator may spend: it is the float this curve owes to anyone who
 * sells back. Spending it on the real-world asset would leave a fractional reserve that only
 * works while inflows exceed outflows.
 *
 * {redeemForConversion} is the ONE path that turns reserve into capex, and it is safe precisely
 * because it retires the matching claim in the same transaction: the A crossing to Product B is
 * BURNED, so the quote it could have redeemed for stops being owed. The invariant "every
 * outstanding A can still sell back at the curve/AMM price" holds before and after.
 *
 * Pre-graduation it releases the exact top-of-curve integral for those shares — arithmetically
 * identical to that holder selling, except the proceeds fund the asset and the share does not
 * return to inventory. Post-graduation the reserve lives in the AMM, so it withdraws the same
 * proportion of this curve's (otherwise permanently locked) LP position and burns the share side
 * along with it, leaving quote-per-circulating-A untouched.
 *
 * NOTE (§4.2, open): with DOBX as the quote token what is released is DOBX, and funding a
 * physical asset means selling it — the sink and the capex pull in opposite directions. That is
 * an economic tension, not something this contract can resolve.
 */
contract AgentBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;

    IERC20 public immutable shareToken;
    IERC20 public immutable quoteToken; // DOBX

    uint256 public immutable basePrice;       // quote base units per whole share at sold=0
    uint256 public immutable slope;           // quote base units added per whole share sold
    uint256 public immutable sellFeeBps;
    uint256 public immutable buyFeeBps;
    uint256 public immutable graduationRaise;
    uint256 public immutable curveSupply;     // total WHOLE shares held at launch (donation-proof)
    address public immutable feeRecipient;
    address public immutable treasury;        // receives leftover A inventory at graduation
    address public immutable launchpad;       // deployer; the only address that may bind a controller

    uint256 public sold;    // WHOLE shares outstanding in the market (redeemable against the reserve)
    uint256 public burned;  // WHOLE shares permanently retired by A→B conversion
    uint256 public raised;  // net quote held by the curve (seeds the AMM)
    uint256 public capexReleased; // cumulative quote sent to the controller to fund the asset
    bool public graduated;
    AgentAMM public amm;

    /// @notice The {AgentController} allowed to convert A→B. Bound once, then immutable forever.
    address public controller;

    event Bought(address indexed buyer, uint256 wholeShares, uint256 cost, uint256 fee, uint256 newPrice);
    event Sold(address indexed seller, uint256 wholeShares, uint256 proceeds, uint256 newPrice);
    event Graduated(address indexed amm, uint256 seedShares, uint256 seedQuote, uint256 seedPrice, uint256 leftoverToTreasury);
    event ControllerBound(address indexed controller);
    event ConversionRedeemed(uint256 wholeSharesBurned, uint256 quoteReleased, bool postGraduation);

    modifier ensure(uint256 deadline) {
        require(block.timestamp <= deadline, "expired");
        _;
    }

    constructor(
        address _shareToken,
        address _quoteToken,
        uint256 _basePrice,
        uint256 _slope,
        uint256 _sellFeeBps,
        uint256 _buyFeeBps,
        uint256 _graduationRaise,
        uint256 _curveSupply,
        address _feeRecipient,
        address _treasury
    ) {
        require(_shareToken != address(0) && _quoteToken != address(0), "zero addr");
        require(_basePrice > 0 && _graduationRaise > 0 && _curveSupply > 0, "zero param");
        require(_feeRecipient != address(0) && _treasury != address(0), "zero recipient");
        require(_sellFeeBps <= 1000 && _buyFeeBps <= 1000, "fee too high");
        shareToken = IERC20(_shareToken);
        quoteToken = IERC20(_quoteToken);
        basePrice = _basePrice;
        slope = _slope;
        sellFeeBps = _sellFeeBps;
        buyFeeBps = _buyFeeBps;
        graduationRaise = _graduationRaise;
        curveSupply = _curveSupply;
        feeRecipient = _feeRecipient;
        treasury = _treasury;
        launchpad = msg.sender;
    }

    // ─── Controller binding ────────────────────────────────────────────────────

    /**
     * @notice Bind the {AgentController} that may burn A for conversion. Callable ONCE, by the
     *         launchpad that deployed this curve.
     *
     * Set-once (not settable, not clearable) on purpose: the controller is the only address that
     * can ever pull reserve out of this curve, so allowing it to be re-pointed later would
     * reintroduce exactly the discretionary fund path the design removes.
     */
    function bindController(address _controller) external {
        require(msg.sender == launchpad, "not launchpad");
        require(controller == address(0), "already bound");
        require(_controller != address(0), "zero addr");
        controller = _controller;
        emit ControllerBound(_controller);
    }

    // ─── Trading ──────────────────────────────────────────────────────────────

    function buy(uint256 wholeShares, uint256 maxQuoteCost, uint256 deadline) external ensure(deadline) nonReentrant {
        require(!graduated, "graduated");
        // strict `<` reserves ≥1 whole share so graduation always has inventory to seed the AMM
        require(wholeShares > 0 && sold + burned + wholeShares < curveSupply, "exceeds inventory");

        uint256 cost = getBuyCost(wholeShares);
        uint256 fee = (cost * buyFeeBps) / 10000;
        uint256 total = cost + fee;
        require(total > 0 && total <= maxQuoteCost, "slippage");

        sold += wholeShares;
        raised += cost;

        quoteToken.safeTransferFrom(msg.sender, address(this), total);
        if (fee > 0) quoteToken.safeTransfer(feeRecipient, fee);
        shareToken.safeTransfer(msg.sender, wholeShares * SHARE_UNIT);

        emit Bought(msg.sender, wholeShares, cost, fee, getCurrentPrice());

        if (raised >= graduationRaise) _graduate();
    }

    function sell(uint256 wholeShares, uint256 minQuoteOut, uint256 deadline) external ensure(deadline) nonReentrant {
        require(!graduated, "graduated");
        require(wholeShares > 0 && wholeShares <= sold, "bad amount");

        uint256 proceeds = getSellProceeds(wholeShares);
        require(proceeds >= minQuoteOut, "slippage");
        require(proceeds <= raised, "insufficient reserve");

        sold -= wholeShares;
        raised -= proceeds;

        shareToken.safeTransferFrom(msg.sender, address(this), wholeShares * SHARE_UNIT);
        quoteToken.safeTransfer(msg.sender, proceeds);

        emit Sold(msg.sender, wholeShares, proceeds, getCurrentPrice());
    }

    // ─── Conversion sink (A→B): burn A, release its reserve share as capex ──────

    /**
     * @notice Burn `wholeShares` of A on behalf of the bound controller and release the reserve
     *         those shares represented. The controller must have approved this curve for the A.
     * @dev Reverts unless called by the bound {AgentController} — this is the only non-trading
     *      path by which quote ever leaves the curve, and it always retires the matching claim.
     * @param wholeShares whole A shares crossing to Product B
     * @param minQuoteOut floor on the released amount. Post-graduation the release is a
     *        proportional LP withdrawal, so a same-block swap can skew the pool's composition and
     *        shrink the quote leg; this bounds that grief (the attacker gains nothing but pays
     *        the AMM fee twice, so it is nuisance rather than extraction).
     * @return releasedQuote quote sent to the controller to fund the real-world asset
     */
    function redeemForConversion(uint256 wholeShares, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 releasedQuote)
    {
        require(msg.sender == controller, "not controller");
        require(wholeShares > 0, "zero");

        uint256 baseAmount = wholeShares * SHARE_UNIT;
        shareToken.safeTransferFrom(msg.sender, address(this), baseAmount);

        if (!graduated) {
            // Pre-graduation: release exactly the top-of-curve integral for these shares — the
            // same arithmetic as a sell, so the remaining `sold` stay fully covered by `raised`.
            require(wholeShares <= sold, "exceeds outstanding");
            releasedQuote = _integralFrom(sold - wholeShares, wholeShares);
            require(releasedQuote <= raised, "insufficient reserve");
            sold -= wholeShares;
            raised -= releasedQuote;
        } else {
            // Post-graduation: the reserve is the AMM's quote leg. Withdraw the same share of
            // this curve's LP as the A being retired is of circulating A, and burn the share leg
            // that comes back with it — quote-per-circulating-A is unchanged for everyone left.
            uint256 circulating = shareToken.totalSupply() - shareToken.balanceOf(address(amm));
            require(circulating >= baseAmount, "bad circulating");
            uint256 lp = amm.liquidityBalance(address(this));
            uint256 lpToRemove = (lp * baseAmount) / circulating;
            if (lpToRemove > 0) {
                (uint256 shareOut, uint256 quoteOut) =
                    amm.removeLiquidity(lpToRemove, 0, minQuoteOut, block.timestamp);
                releasedQuote = quoteOut;
                if (shareOut > 0) AgentShareToken(address(shareToken)).burn(shareOut);
            }
        }

        require(releasedQuote >= minQuoteOut, "slippage");

        burned += wholeShares;
        capexReleased += releasedQuote;
        AgentShareToken(address(shareToken)).burn(baseAmount);
        if (releasedQuote > 0) quoteToken.safeTransfer(controller, releasedQuote);

        emit ConversionRedeemed(wholeShares, releasedQuote, graduated);
    }

    // ─── Graduation (seed AMM at ~terminal price; leftover A → treasury) ────────

    function _graduate() internal {
        graduated = true;

        uint256 remainingWhole = curveSupply - sold - burned;  // donation-proof, ≥1 (buy cap)
        uint256 termPrice = getCurrentPrice();                 // quote per whole share
        uint256 quoteLiquidity = raised;

        // Seed shares chosen so AMM price ≈ terminal curve price → no discontinuity.
        // Clamped to [1, remainingWhole] so graduation never reverts on degenerate configs.
        uint256 seedWhole = quoteLiquidity / termPrice;
        if (seedWhole == 0) seedWhole = 1;
        if (seedWhole > remainingWhole) seedWhole = remainingWhole;

        uint256 seedBase = seedWhole * SHARE_UNIT;
        uint256 leftoverBase = (remainingWhole - seedWhole) * SHARE_UNIT;

        AgentAMM pool = new AgentAMM(address(shareToken), address(quoteToken));
        amm = pool;

        shareToken.forceApprove(address(pool), seedBase);
        quoteToken.forceApprove(address(pool), quoteLiquidity);
        // LP minted to this curve. The curve exposes no general removeLiquidity, so the position
        // is locked — {redeemForConversion} is the sole, claim-retiring exception.
        pool.addLiquidity(seedBase, quoteLiquidity, seedBase, quoteLiquidity, block.timestamp);

        if (leftoverBase > 0) shareToken.safeTransfer(treasury, leftoverBase);

        uint256 seedPrice = quoteLiquidity / seedWhole; // ≈ termPrice
        emit Graduated(address(pool), seedWhole, quoteLiquidity, seedPrice, leftoverBase);
    }

    // ─── Pricing (per whole share, exact integer arithmetic) ───────────────────

    function getCurrentPrice() public view returns (uint256) {
        return basePrice + (sold * slope);
    }

    function getBuyCost(uint256 k) public view returns (uint256) {
        return _integralFrom(sold, k);
    }

    function getSellProceeds(uint256 k) public view returns (uint256) {
        require(k <= sold, "exceeds sold");
        uint256 gross = _integralFrom(sold - k, k);
        uint256 fee = (gross * sellFeeBps) / 10000;
        return gross - fee;
    }

    /// @dev Exact integral of the linear price over the k shares starting at position `from`.
    function _integralFrom(uint256 from, uint256 k) internal view returns (uint256) {
        if (k == 0) return 0;
        return k * basePrice + (slope * (2 * from + k - 1) * k) / 2;
    }

    /// @notice Whole shares still available to buy on the curve.
    function inventory() external view returns (uint256) {
        return curveSupply - sold - burned;
    }
}
