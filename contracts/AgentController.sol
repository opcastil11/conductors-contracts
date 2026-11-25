// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./AgentBondingCurve.sol";
import "./KycRegistry.sol";

/**
 * @title AgentController
 * @notice The pool admin of one agent — a CONTRACT, not a wallet (docs/TOKENOMICS-V2.md §3.2).
 *         It is the one-way A→B crossing, the custodian of the creator's retained B, and the
 *         only address that can turn curve reserve into capex.
 *
 * ─── Why a contract holds pool admin ────────────────────────────────────────────────────────
 *
 * The open question in the earlier draft was whether `soro_splitter` exposes an admin sweep —
 * i.e. whether the operator could take back the A that converters paid in. Assigning pool admin
 * here makes the question moot: if the only address that could make that call exposes no such
 * call, the sweep cannot happen no matter what the splitter allows. "El A convertido queda
 * inmovilizado" stops being a promise and becomes a property of the bytecode.
 *
 * ─── No sweep, and no key that could add one ────────────────────────────────────────────────
 *
 * A guarantee is only worth its upgrade key, so this contract has none. There is no `owner`, no
 * proxy, no initializer, no setter — every address and every schedule is `immutable` or fixed at
 * {activate}, which only the launchpad can call, once. The complete list of ways value leaves is:
 *
 *   1. quote → `capexSink`, inside {convert}, exactly the amount the curve just released;
 *   2. B → the converter, at the fixed ratio derived at activation;
 *   3. B → `creator`, never more than the vesting schedule allows.
 *
 * Each is formula-bound with no caller discretion. Nothing else can move. (A corollary: tokens
 * sent here by mistake are stuck forever — the cost of having no rescue function is exactly what
 * makes the guarantee credible, so it is accepted rather than patched.)
 *
 * ─── The conversion ratio, and why it is not always 1:1 ─────────────────────────────────────
 *
 * B is issued against the same cap as A, but the creator retains `participation_to_sale`'s
 * complement, so only `convertibleB` is reachable by converters. Rather than let the first
 * arrivals take 1:1 until B runs out and leave the rest with nothing, every A converts at the
 * SAME ratio `convertibleB / aSupplyAtActivation`. With 30% retained, every A converts to 0.7 B
 * — which is precisely why §6.2 states that each retained point lowers A's floor
 * proportionally. Retention and floor strength are one dial seen from two sides. 1:1 is the
 * special case where the creator retains nothing.
 *
 * ─── Grace period ───────────────────────────────────────────────────────────────────────────
 *
 * Conversion is closed until `graceEnd`. During grace B pays nothing, so converting would mean
 * trading a liquid token for a claim that has not begun amortizing; closing it outright makes
 * that explicit and gives A the full attention-market window its value depends on (§6.1).
 */
contract AgentController is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;
    uint256 public constant BPS = 10_000;

    // ─── Immutable wiring ──────────────────────────────────────────────────────
    IERC20 public immutable agentToken;          // A
    IERC20 public immutable participationToken;  // B (DobProtocol participation)
    IERC20 public immutable quoteToken;          // DOBX
    AgentBondingCurve public immutable curve;
    address public immutable creator;            // beneficiary of the retained B
    address public immutable capexSink;          // funds the real-world asset; the ONLY quote exit
    IKycRegistry public immutable kyc;           // address(0) ⇒ ungated (testnet only)
    address public immutable activator;          // the launchpad: the only address that may activate

    uint16 public immutable retainedBps;         // creator's share of B (100% - participation_to_sale)
    uint64 public immutable graceSeconds;        // conversion closed for this long after activation
    uint64 public immutable cliffSeconds;        // retained B: nothing vests before this
    uint64 public immutable vestSeconds;         // retained B: linear over this window after the cliff

    // ─── Activation snapshot ───────────────────────────────────────────────────
    bool public activated;
    uint256 public convertibleB;           // B reachable by converters
    uint256 public retainedB;              // B locked for the creator
    uint256 public aSupplyAtActivation;    // A's supply when the crossing opened (informational)
    uint64 public graceEnd;
    uint64 public cliffEnd;
    uint64 public vestEnd;

    // ─── Running totals ────────────────────────────────────────────────────────
    uint256 public bConverted;     // B handed to converters so far
    uint256 public bReleased;      // B released to the creator so far
    uint256 public aBurned;        // whole A shares retired through this controller
    uint256 public capexFunded;    // quote forwarded to capexSink

    // The rate is B still unconverted over A still outside the curve's pool position, recomputed
    // on every conversion. A fixed denominator counted the A the curve seeded into the AMM — burned
    // on conversion without ever claiming B — and left that share of B unreachable. The curve's
    // position is valued at the AMM's 1-hour time-weighted A per LP unit, and a conversion is
    // refused while the spot sits more than MAX_DEVIATION_BPS away from it in either direction:
    // moving the rate means moving the pool AND holding it there for an hour against arbitrage. The
    // conversion that leaves under one whole A outside takes whatever rounding left behind.
    uint64 public constant TWAP_WINDOW = 1 hours;
    uint256 public constant MAX_DEVIATION_BPS = 300;

    event Activated(uint256 totalB, uint256 convertibleB, uint256 retainedB, uint256 aSupply, uint64 graceEnd);
    event Converted(address indexed account, uint256 wholeSharesA, uint256 bOut, uint256 quoteToCapex);
    event RetainedReleased(address indexed creator, uint256 amount);

    constructor(
        address _agentToken,
        address _participationToken,
        address _quoteToken,
        address _curve,
        address _creator,
        address _capexSink,
        address _kyc,
        address _activator,
        uint16 _retainedBps,
        uint64 _graceSeconds,
        uint64 _cliffSeconds,
        uint64 _vestSeconds
    ) {
        require(_agentToken != address(0) && _participationToken != address(0), "zero token");
        require(_quoteToken != address(0) && _curve != address(0), "zero addr");
        require(_creator != address(0) && _capexSink != address(0), "zero recipient");
        require(_activator != address(0), "zero activator");
        require(_retainedBps <= BPS / 2, "retain too much"); // most B must stay convertible or A has no floor
        require(_graceSeconds <= 365 days && _cliffSeconds <= 4 * 365 days && _vestSeconds <= 4 * 365 days, "schedule too long");
        agentToken = IERC20(_agentToken);
        participationToken = IERC20(_participationToken);
        quoteToken = IERC20(_quoteToken);
        curve = AgentBondingCurve(_curve);
        creator = _creator;
        capexSink = _capexSink;
        kyc = IKycRegistry(_kyc);
        activator = _activator;
        retainedBps = _retainedBps;
        graceSeconds = _graceSeconds;
        cliffSeconds = _cliffSeconds;
        vestSeconds = _vestSeconds;
    }

    // ─── Activation ────────────────────────────────────────────────────────────

    /**
     * @notice Split `totalB` convertible/retained and start the grace and vesting clocks.
     *         Callable once, and only by the launchpad (which exposes it to its owner).
     *
     * Not permissionless, and the amount is stated rather than read: the split is fixed forever
     * by this one call, so letting anyone trigger it on whatever balance happened to be here
     * would let a stranger freeze the crossing on a dust balance before the real B arrived.
     * B beyond `totalB` (a donation) is simply not distributable.
     * @dev Call after the DobProtocol pool has issued B to this address.
     */
    function activate(uint256 totalB) external {
        require(msg.sender == activator, "not activator");
        require(!activated, "activated");
        require(totalB > 0, "no B");
        require(participationToken.balanceOf(address(this)) >= totalB, "B not here");
        // The ratio is fixed on A's supply, which is only final once graduation burns the unsold A.
        require(curve.graduated(), "not graduated");
        uint256 aSupply = agentToken.totalSupply();
        require(aSupply > 0, "no A");

        activated = true;
        retainedB = (totalB * retainedBps) / BPS;
        convertibleB = totalB - retainedB;
        // Precision floor: one whole A must be worth ≥1e6 wei of B, so per-conversion rounding is negligible.
        require(convertibleB * 1e12 >= aSupply, "B too coarse");
        aSupplyAtActivation = aSupply;
        graceEnd = uint64(block.timestamp) + graceSeconds;
        cliffEnd = uint64(block.timestamp) + cliffSeconds;
        vestEnd = cliffEnd + vestSeconds;

        emit Activated(totalB, convertibleB, retainedB, aSupply, graceEnd);
    }

    // ─── The crossing ──────────────────────────────────────────────────────────

    /**
     * @notice Convert `wholeShares` of A into B, one way and forever. The A is burned by the
     *         curve, which releases the reserve backing it straight through to `capexSink`.
     * @param wholeShares whole A shares to cross (the caller must approve this contract first)
     * @param minQuoteToCapex floor on the reserve released; see {AgentBondingCurve-redeemForConversion}
     * @return bOut participation tokens delivered to the caller
     */
    function convert(uint256 wholeShares, uint256 minQuoteToCapex)
        external
        nonReentrant
        returns (uint256 bOut)
    {
        return _convert(wholeShares, minQuoteToCapex, 1);
    }

    /// @notice {convert} with a floor on the B received and a deadline.
    function convertWithLimits(uint256 wholeShares, uint256 minQuoteToCapex, uint256 minBOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 bOut)
    {
        require(block.timestamp <= deadline, "expired");
        return _convert(wholeShares, minQuoteToCapex, minBOut);
    }

    function _convert(uint256 wholeShares, uint256 minQuoteToCapex, uint256 minBOut) internal returns (uint256 bOut) {
        require(activated, "not activated");
        require(block.timestamp >= graceEnd, "grace period");
        require(wholeShares > 0, "zero");
        require(address(kyc) == address(0) || kyc.isApproved(msg.sender), "kyc required");

        uint256 aIn = wholeShares * SHARE_UNIT;
        (uint256 num, uint256 den, bool settled) = _rate();
        require(settled, "pool unsettled");
        require(den > 0, "no outstanding A");
        bOut = (aIn * num) / den;
        // Terminal sweep: this conversion leaves less than one whole A outside the curve's pool.
        if (bOut > num || den < aIn + SHARE_UNIT) bOut = num;
        require(bOut > 0, "dust");
        require(bOut >= minBOut, "slippage");
        require(bConverted + bOut <= convertibleB, "convertible exhausted");

        bConverted += bOut;
        aBurned += wholeShares;

        // Pull the A, hand it to the curve to burn, and take back the reserve it frees.
        agentToken.safeTransferFrom(msg.sender, address(this), aIn);
        IERC20(address(agentToken)).forceApprove(address(curve), aIn);
        uint256 released = curve.redeemForConversion(wholeShares, minQuoteToCapex);

        // Straight through — this contract is a conduit for capex, never a treasury.
        if (released > 0) {
            capexFunded += released;
            quoteToken.safeTransfer(capexSink, released);
        }
        participationToken.safeTransfer(msg.sender, bOut);

        emit Converted(msg.sender, wholeShares, bOut, released);
    }

    function _rate() internal view returns (uint256 num, uint256 den, bool settled) {
        AgentAMM pool = curve.amm();
        uint256 supply = agentToken.totalSupply();
        uint256 spot = pool.aPerLpSpot();
        uint256 avg = pool.twapAPerLp(TWAP_WINDOW);
        settled = spot * BPS <= avg * (BPS + MAX_DEVIATION_BPS) && spot * BPS >= avg * (BPS - MAX_DEVIATION_BPS);
        // Valued at the hour's average, not the spot: moving the pool inside the band for one
        // transaction moves the rate by nothing. The band itself stops a skewed average (a held
        // buy-out unwound right before converting) from pricing anyone's conversion.
        uint256 curveShares = (pool.liquidityBalance(address(curve)) * avg) / 1e18;
        den = supply > curveShares ? supply - curveShares : 0;
        num = convertibleB - bConverted;
    }

    /// @notice Whether a conversion would be accepted now (spot within MAX_DEVIATION_BPS of the TWAP).
    function poolSettled() external view returns (bool settled) {
        (, , settled) = _rate();
    }

    /// @notice The current B-per-A rate as (unconverted B, A outside the curve's pool position).
    function conversionRate() public view returns (uint256 num, uint256 den) {
        if (!activated) return (0, 0);
        (num, den, ) = _rate();
    }

    /// @notice B delivered for `wholeShares` of A at the current rate.
    function quoteConversion(uint256 wholeShares) external view returns (uint256) {
        (uint256 num, uint256 den) = conversionRate();
        if (den == 0) return 0;
        uint256 out = (wholeShares * SHARE_UNIT * num) / den;
        return out > num ? num : out; // the terminal sweep is not quoted
    }

    // ─── Retained B: cliff + linear vesting, pull-based ─────────────────────────

    /// @notice Retained B vested so far (cumulative, including what was already released).
    function vestedRetained() public view returns (uint256) {
        if (!activated || block.timestamp < cliffEnd) return 0;
        if (block.timestamp >= vestEnd) return retainedB;
        return (retainedB * (block.timestamp - cliffEnd)) / (vestEnd - cliffEnd);
    }

    /// @notice Send the creator whatever has vested and not yet been released.
    function releaseRetained() external nonReentrant returns (uint256 amount) {
        amount = vestedRetained() - bReleased;
        require(amount > 0, "nothing vested");
        bReleased += amount;
        participationToken.safeTransfer(creator, amount);
        emit RetainedReleased(creator, amount);
    }
}
