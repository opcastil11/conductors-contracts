// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
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
 *   1. quote → `capexSink`, inside a batch settlement, exactly the amount the curve just released;
 *   2. B → a converter, pro rata to the A it committed to a settled batch;
 *   3. B → `creator`, never more than the vesting schedule allows;
 *   4. A → a requester who cancels before the batch closes (their own A, back);
 *   5. B → `creator`, before activation only ({recoverB}): the crossing never opened.
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

    // ─── Batched conversion ────────────────────────────────────────────────────
    //
    // The rate is B still unconverted over A still outside the curve's pool position, and how much
    // A that position holds depends on the AMM — so any rate read at one instant can be moved by
    // whoever moves the pool at that instant. Conversions are therefore committed first and priced
    // later: requests collect for COLLECT_WINDOW, the batch then closes (snapshotting the AMM's
    // accumulator), and it settles at the pool's time-weighted A per LP unit over the PRICING_WINDOW
    // that follows the close. Nobody who requested knows that average, moving it means holding
    // the pool off its price for a whole day against arbitrage, and there is no band that a
    // passing trade could use to pause the crossing. Everyone in a batch gets the same rate.
    uint64 public constant COLLECT_WINDOW = 12 hours;
    uint64 public constant PRICING_WINDOW = 24 hours;
    // At settlement the window average is checked against the pool's 1-hour average and its spot
    // composition: the batch uses the lowest A-per-LP of the three (the most A outside, the
    // smallest payout), and while they disagree by more than DIVERGENCE_BPS it waits, for up to
    // SETTLE_GRACE. A pool held off its price through the window and released before settlement
    // therefore only delays the batch; overpaying it means holding the skew through settlement.
    // The capex leg is a proportional LP withdrawal at the moment of settlement, so a same-block
    // skew of the pool could shrink it. It is floored against the pool's 1-hour average, within
    // CAPEX_TOLERANCE_BPS while the batch is in its grace and within the wider
    // LATE_CAPEX_TOLERANCE_BPS after it. A batch whose floor cannot be met waits instead of reverting.
    uint64 public constant TWAP_WINDOW = 1 hours;
    uint256 public constant CAPEX_TOLERANCE_BPS = 500;
    uint256 public constant LATE_CAPEX_TOLERANCE_BPS = 2000;
    uint256 public constant DIVERGENCE_BPS = 500;
    uint64 public constant SETTLE_GRACE = 1 days;
    uint256 public constant MAX_SETTLE_PER_CALL = 8;

    struct Batch {
        uint64 openedAt;       // first request
        uint64 closedAt;       // 0 while collecting
        bool settled;
        uint256 closeCum;      // AMM accumulator at close
        uint256 shares;        // whole A shares requested
        uint256 bOut;          // B assigned at settlement
        uint256 claimedShares;
        uint256 claimedB;
    }

    mapping(uint256 => Batch) public batches;
    mapping(uint256 => mapping(address => uint256)) public requested; // batch → account → whole A
    uint256 public openBatch = 1;      // the batch collecting requests
    uint256 public nextToSettle = 1;   // batches settle strictly in order
    uint256 public queuedShares;       // whole A held here for unsettled batches

    event Activated(uint256 totalB, uint256 convertibleB, uint256 retainedB, uint256 aSupply, uint64 graceEnd);
    event ConversionRequested(address indexed account, uint256 indexed batchId, uint256 wholeSharesA);
    event ConversionCancelled(address indexed account, uint256 indexed batchId, uint256 wholeSharesA);
    event BatchClosed(uint256 indexed batchId, uint256 wholeSharesA);
    event BatchSettled(uint256 indexed batchId, uint256 wholeSharesA, uint256 bOut, uint256 quoteToCapex, uint256 aPerLp);
    event Claimed(address indexed account, uint256 indexed batchId, uint256 bOut);
    event BRecovered(address indexed creator, uint256 amount);
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
        // Precision floor: at least one B unit per whole A (B is a 0-decimal token). A conversion
        // loses under one B unit to rounding, and the terminal sweep hands the remainder out.
        require(convertibleB * SHARE_UNIT >= aSupply, "B too coarse");
        aSupplyAtActivation = aSupply;
        graceEnd = uint64(block.timestamp) + graceSeconds;
        cliffEnd = uint64(block.timestamp) + cliffSeconds;
        vestEnd = cliffEnd + vestSeconds;

        emit Activated(totalB, convertibleB, retainedB, aSupply, graceEnd);
    }

    /**
     * @notice Send every B held here back to the creator, before activation only. A crossing that
     *         can never open (B too coarse, wrong amount sent) would otherwise trap that B; after
     *         activation this path is closed and the no-rescue guarantee above is unconditional.
     */
    function recoverB() external nonReentrant returns (uint256 amount) {
        require(msg.sender == activator, "not activator");
        require(!activated, "activated");
        amount = participationToken.balanceOf(address(this));
        require(amount > 0, "no B");
        participationToken.safeTransfer(creator, amount);
        emit BRecovered(creator, amount);
    }

    // ─── The crossing ──────────────────────────────────────────────────────────

    /**
     * @notice Commit `wholeShares` of A to the batch now collecting. The A moves here at once and
     *         crosses at that batch's settlement rate; until the batch closes it can be cancelled.
     * @return batchId the batch to {claim} from once it settles
     */
    function requestConversion(uint256 wholeShares) external nonReentrant returns (uint256 batchId) {
        require(activated, "not activated");
        require(block.timestamp >= graceEnd, "grace period");
        require(wholeShares > 0, "zero");
        require(bConverted < convertibleB, "convertible exhausted");
        require(address(kyc) == address(0) || kyc.isApproved(msg.sender), "kyc required");
        _close();
        batchId = openBatch;
        Batch storage b = batches[batchId];
        if (b.openedAt == 0) b.openedAt = uint64(block.timestamp);
        b.shares += wholeShares;
        requested[batchId][msg.sender] += wholeShares;
        queuedShares += wholeShares;
        agentToken.safeTransferFrom(msg.sender, address(this), wholeShares * SHARE_UNIT);
        emit ConversionRequested(msg.sender, batchId, wholeShares);
    }

    /// @notice Take back A from the batch still collecting (not once it has closed).
    function cancelRequest(uint256 batchId, uint256 wholeShares) external nonReentrant {
        _close();
        require(batchId == openBatch, "batch closed");
        require(wholeShares > 0 && requested[batchId][msg.sender] >= wholeShares, "not requested");
        requested[batchId][msg.sender] -= wholeShares;
        Batch storage b = batches[batchId];
        b.shares -= wholeShares;
        if (b.shares == 0) b.openedAt = 0; // an emptied batch restarts its window with the next request
        queuedShares -= wholeShares;
        agentToken.safeTransfer(msg.sender, wholeShares * SHARE_UNIT);
        emit ConversionCancelled(msg.sender, batchId, wholeShares);
    }

    /// @notice Close the collecting batch if its window has run, and settle what is due. Anyone.
    function poke() external nonReentrant returns (uint256 settledCount) {
        _close();
        settledCount = _settleDue(type(uint256).max);
    }

    /**
     * @notice Collect the B of `batchId` (settling it, and any earlier batch, first if due).
     *         Pro rata to the A requested; the last claimant takes the rounding remainder.
     */
    function claim(uint256 batchId) external nonReentrant returns (uint256 bOut) {
        _close();
        _settleDue(batchId);
        Batch storage b = batches[batchId];
        require(b.settled, "not settled");
        uint256 shares = requested[batchId][msg.sender];
        require(shares > 0, "nothing to claim");
        requested[batchId][msg.sender] = 0;
        b.claimedShares += shares;
        bOut = b.claimedShares == b.shares ? b.bOut - b.claimedB : (shares * b.bOut) / b.shares;
        b.claimedB += bOut;
        if (bOut > 0) participationToken.safeTransfer(msg.sender, bOut);
        emit Claimed(msg.sender, batchId, bOut);
    }

    function _close() internal {
        Batch storage b = batches[openBatch];
        if (b.openedAt == 0 || b.shares == 0 || block.timestamp < b.openedAt + COLLECT_WINDOW) return;
        b.closedAt = uint64(block.timestamp);
        b.closeCum = curve.amm().aPerLpCumulativeNow();
        emit BatchClosed(openBatch, b.shares);
        openBatch++;
    }

    function _due(uint256 id) internal view returns (bool) {
        Batch storage b = batches[id];
        return id < openBatch && b.closedAt != 0 && !b.settled && block.timestamp >= b.closedAt + PRICING_WINDOW;
    }

    /// @dev Settle due batches in order, up to `upTo` and MAX_SETTLE_PER_CALL of them.
    function _settleDue(uint256 upTo) internal returns (uint256 n) {
        while (n < MAX_SETTLE_PER_CALL && nextToSettle <= upTo) {
            if (!_due(nextToSettle) || !_settle(nextToSettle)) break;
            nextToSettle++;
            n++;
        }
    }

    /// @dev Returns false (and changes nothing) when the batch must wait: the window average and
    ///      the 1-hour average disagree during the grace, or the capex floor cannot be met now.
    function _settle(uint256 id) internal returns (bool) {
        Batch storage b = batches[id];
        (bool ok, uint256 bOut, uint256 lpOut, uint256 minQuote, uint256 avg) = _plan(b);
        if (!ok) return false;
        uint256 aIn = b.shares * SHARE_UNIT;

        b.settled = true;
        b.bOut = bOut;
        bConverted += bOut;
        aBurned += b.shares;
        queuedShares -= b.shares;

        IERC20(address(agentToken)).forceApprove(address(curve), aIn);
        uint256 released = curve.redeemForConversion(b.shares, lpOut, minQuote);
        // Straight through — this contract is a conduit for capex, never a treasury.
        if (released > 0) {
            capexFunded += released;
            quoteToken.safeTransfer(capexSink, released);
        }
        emit BatchSettled(id, b.shares, bOut, released, avg);
        return true;
    }

    function _plan(Batch storage b)
        internal
        view
        returns (bool ok, uint256 bOut, uint256 lpOut, uint256 minQuote, uint256 avg)
    {
        AgentAMM pool = curve.amm();
        bool inGrace = block.timestamp < b.closedAt + PRICING_WINDOW + SETTLE_GRACE;
        uint256 windowAvg = (pool.aPerLpCumulativeNow() - b.closeCum) / (block.timestamp - b.closedAt);
        uint256 shortAvg = windowAvg;
        try pool.twapAPerLp(TWAP_WINDOW) returns (uint256 sa) { if (sa > 0) shortAvg = sa; } catch {}
        {
            uint256 spot = pool.aPerLpSpot();
            uint256 hi = Math.max(windowAvg, Math.max(shortAvg, spot));
            avg = Math.min(windowAvg, Math.min(shortAvg, spot));
            if (inGrace && (hi - avg) * BPS > hi * DIVERGENCE_BPS) return (false, 0, 0, 0, avg);
        }
        uint256 lp = pool.liquidityBalance(address(curve));
        uint256 aIn = b.shares * SHARE_UNIT;
        uint256 outside = _outside(pool, lp, avg);
        uint256 num = convertibleB - bConverted;
        // Terminal sweep: under one whole A would remain outside — this batch takes what is left.
        if (outside < aIn + SHARE_UNIT) {
            bOut = num;
            lpOut = lp;
        } else {
            bOut = (aIn * num) / outside;
            lpOut = (lp * aIn) / outside;
        }
        uint256 tol = inGrace ? CAPEX_TOLERANCE_BPS : LATE_CAPEX_TOLERANCE_BPS;
        minQuote = (_fairQuote(pool, lpOut, shortAvg) * (BPS - tol)) / BPS;
        uint256 L = pool.totalLiquidity();
        if (lpOut > 0 && (L == 0 || (lpOut * pool.quoteReserve()) / L < minQuote)) return (false, 0, 0, 0, avg);
        ok = true;
    }

    /// @dev A that can still claim B: the supply, less the curve's pool position valued at `avg`,
    ///      less A nobody can ever bring here (untracked A sitting in the AMM, A held by the curve,
    ///      A donated to this contract). Never below the A already queued, which certainly claims.
    function _outside(AgentAMM pool, uint256 lp, uint256 avg) internal view returns (uint256) {
        uint256 excluded = (lp * avg) / 1e18 + agentToken.balanceOf(address(curve));
        uint256 ammBal = agentToken.balanceOf(address(pool));
        uint256 tracked = pool.shareReserve();
        if (ammBal > tracked) excluded += ammBal - tracked;
        uint256 queued = queuedShares * SHARE_UNIT;
        uint256 held = agentToken.balanceOf(address(this));
        if (held > queued) excluded += held - queued;
        uint256 supply = agentToken.totalSupply();
        uint256 outside = supply > excluded ? supply - excluded : 0;
        return outside > queued ? outside : queued;
    }

    /// @dev Quote that `lpOut` would release at A-per-LP `avg` (the 1-hour average): quote per
    ///      LP unit is (k / L²) / (A per LP unit), and only swaps move A per LP.
    function _fairQuote(AgentAMM pool, uint256 lpOut, uint256 avg) internal view returns (uint256) {
        uint256 L = pool.totalLiquidity();
        if (avg == 0 || L == 0 || lpOut == 0) return 0;
        uint256 perL = Math.mulDiv(pool.shareReserve(), pool.quoteReserve(), L); // k / L
        return Math.mulDiv(Math.mulDiv(lpOut, perL, L), 1e18, avg);
    }

    // ─── Views (estimates; never revert) ───────────────────────────────────────

    /// @notice An estimate of the B-per-A rate as (unconverted B, A outside the curve's position),
    ///         at the pool's 1-hour average. The binding rate is fixed only at each batch's settlement.
    function conversionRate() public view returns (uint256 num, uint256 den) {
        if (!activated) return (0, 0);
        AgentAMM pool = curve.amm();
        uint256 avg;
        try pool.twapAPerLp(TWAP_WINDOW) returns (uint256 a) { avg = a; } catch { avg = pool.aPerLpSpot(); }
        num = convertibleB - bConverted;
        den = _outside(pool, pool.liquidityBalance(address(curve)), avg);
    }

    /// @notice Estimated B for `wholeShares` of A at {conversionRate}.
    function quoteConversion(uint256 wholeShares) external view returns (uint256) {
        (uint256 num, uint256 den) = conversionRate();
        if (den == 0) return 0;
        uint256 out = (wholeShares * SHARE_UNIT * num) / den;
        return out > num ? num : out;
    }

    /// @notice When `batchId` can settle (0 if it is not collecting or closed yet).
    function settlesAt(uint256 batchId) external view returns (uint256) {
        Batch storage b = batches[batchId];
        if (b.closedAt != 0) return uint256(b.closedAt) + PRICING_WINDOW;
        if (b.openedAt != 0) return uint256(b.openedAt) + COLLECT_WINDOW + PRICING_WINDOW;
        return 0;
    }

    /// @notice B `account` can claim from `batchId` now (0 until it settles).
    function claimable(uint256 batchId, address account) external view returns (uint256) {
        Batch storage b = batches[batchId];
        uint256 shares = requested[batchId][account];
        if (!b.settled || shares == 0) return 0;
        if (b.claimedShares + shares == b.shares) return b.bOut - b.claimedB;
        return (shares * b.bOut) / b.shares;
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
