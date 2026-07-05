// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./AgentAMM.sol";

/**
 * @title AgentBondingCurve
 * @notice Fair-launch bonding curve for one agent's shares (Product A), priced per WHOLE share
 *         in USDC. Linear: price(i) = basePrice + i*slope; cost = the exact integral.
 *
 * Security-hardened vs the initial draft (audit fixes):
 *  - **No graduation price cliff**: the AMM is seeded at ~the curve's terminal price
 *    (`seedShares = raised / terminalPrice`), not by dumping the whole inventory. Leftover
 *    inventory goes to the treasury, so a back-runner can't buy the float far below what curve
 *    buyers paid.
 *  - **Donation-proof inventory**: remaining shares are computed from an immutable `curveSupply`
 *    minus `sold`, never `balanceOf`, so donating shares can't skew the seed.
 *  - **Deadlines** on buy/sell to bound MEV/held-tx execution.
 *  - Fee ceiling tightened; graduation-config sanity is enforced by the launchpad.
 *
 * The whole supply is minted to this curve by the {AgentLaunchpad} right after deploy.
 */
contract AgentBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;

    IERC20 public immutable shareToken;
    IERC20 public immutable quoteToken; // USDC

    uint256 public immutable basePrice;       // USDC base units per whole share at sold=0
    uint256 public immutable slope;           // USDC base units added per whole share sold
    uint256 public immutable sellFeeBps;
    uint256 public immutable buyFeeBps;
    uint256 public immutable graduationRaise;
    uint256 public immutable curveSupply;     // total WHOLE shares held at launch (donation-proof)
    address public immutable feeRecipient;
    address public immutable treasury;        // receives leftover A inventory at graduation

    uint256 public sold;    // WHOLE shares sold
    uint256 public raised;  // net USDC held by the curve (seeds the AMM)
    bool public graduated;
    AgentAMM public amm;

    event Bought(address indexed buyer, uint256 wholeShares, uint256 cost, uint256 fee, uint256 newPrice);
    event Sold(address indexed seller, uint256 wholeShares, uint256 proceeds, uint256 newPrice);
    event Graduated(address indexed amm, uint256 seedShares, uint256 seedQuote, uint256 seedPrice, uint256 leftoverToTreasury);

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
    }

    // ─── Trading ──────────────────────────────────────────────────────────────

    function buy(uint256 wholeShares, uint256 maxQuoteCost, uint256 deadline) external ensure(deadline) nonReentrant {
        require(!graduated, "graduated");
        // strict `<` reserves ≥1 whole share so graduation always has inventory to seed the AMM
        require(wholeShares > 0 && sold + wholeShares < curveSupply, "exceeds inventory");

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

    // ─── Graduation (seed AMM at ~terminal price; leftover A → treasury) ────────

    function _graduate() internal {
        graduated = true;

        uint256 remainingWhole = curveSupply - sold;         // donation-proof, ≥1 (buy cap)
        uint256 termPrice = getCurrentPrice();               // USDC per whole share
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
        // LP minted to this curve; the curve exposes no removeLiquidity → liquidity locked.
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
        return k * basePrice + (slope * (2 * sold + k - 1) * k) / 2;
    }

    function getSellProceeds(uint256 k) public view returns (uint256) {
        require(k <= sold, "exceeds sold");
        uint256 gross = k * basePrice + (slope * (2 * (sold - k) + k - 1) * k) / 2;
        uint256 fee = (gross * sellFeeBps) / 10000;
        return gross - fee;
    }

    /// @notice Whole shares still available to buy on the curve.
    function inventory() external view returns (uint256) {
        return curveSupply - sold;
    }
}
