// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./AgentShareToken.sol";
import "./AgentBondingCurve.sol";
import "./AgentCurveFactory.sol";
import "./AgentControllerFactory.sol";

/**
 * @title AgentLaunchpad
 * @notice Factory + registry for Conductors agent fair launches (Product A). Each launch deploys an
 *         {AgentShareToken} (fixed supply) + an {AgentBondingCurve} quoted in DOBX, mints the
 *         supply into the curve, validates the economics, and records the trio. Once the agent's
 *         DobProtocol pool exists, {deployController} attaches the {AgentController} that owns
 *         the A→B crossing.
 *
 * Security-hardened vs the initial draft (audit fixes):
 *  - **Gated launches**: `launch()` is restricted to authorized launchers (the Conductors backend /
 *    verified operators) unless `publicLaunch` is enabled — enforcing on-chain the "gated
 *    off-chain" intent and preventing spam/impersonation.
 *  - **Pausable** launching.
 *  - **Config validation**: rejects graduation targets that are unreachable or that would make
 *    the AMM seed revert / be pathological.
 *  - Fee caps enforced here AND (tighter) in the curve.
 *
 * Note: `name`/`symbol` are attacker-controllable in principle; frontends MUST use the
 * registry `agentId`/addresses as identity, never the string metadata.
 */
contract AgentLaunchpad is Ownable, Pausable {
    using SafeERC20 for IERC20;

    /**
     * @notice The quote token every NEW curve is priced in — DOBX (docs/TOKENOMICS-V2.md §2).
     * @dev Changing this only affects launches from here on: {AgentBondingCurve-quoteToken} is
     *      `immutable`, so each curve is welded to whatever this held at its launch. Agents
     *      launched against the old quote token cannot be re-pointed — migrating them means
     *      RELAUNCHING them. That is a known, accepted cost of the switch, not a bug to route
     *      around.
     */
    IERC20 public immutable quoteToken; // fixed: a new quote token is a new launchpad
    address public platformTreasury;  // fee recipient (the curve burns its leftover A at graduation)
    IKycRegistry public kycRegistry;  // gate applied at the A→B crossing; 0 ⇒ ungated (testnet)
    AgentCurveFactory public immutable curveFactory; // created here; holds the curve's creation code (size split)
    AgentControllerFactory public controllerFactory; // holds AgentController's creation code (size split)
    address public pendingControllerFactory;         // proposed replacement, live after FACTORY_DELAY
    uint256 public pendingControllerFactoryAt;       // earliest time it can be accepted (0 = none)
    uint16 public maxBuyFeeBps = 500;  // 5%
    uint16 public maxSellFeeBps = 500; // 5%
    bool public publicLaunch;          // if false, only authorized launchers may launch

    // Bounds on what the owner can stamp into a controller. Every value is immutable once deployed,
    // so these caps are what limits a compromised or careless owner key.
    uint16 public constant MAX_RETAINED_BPS = 5000;     // creator keeps at most half of B
    uint64 public constant MAX_GRACE = 365 days;
    uint64 public constant MAX_CLIFF = 4 * 365 days;
    uint64 public constant MAX_VEST = 4 * 365 days;
    uint256 public constant FACTORY_DELAY = 2 days;     // notice before a new controller factory applies
    uint256 public constant CONFIG_DELAY = 2 days;      // notice before a new treasury or KYC registry applies
    // Conversion stays closed at least this long after activation, so every controller's
    // parameters (B token, capex sink, split, schedule) are public before any A can cross into it.
    uint64 public constant MIN_GRACE = 2 days;
    mapping(address => bool) public authorizedLauncher;

    struct Launch {
        address token;
        address curve;
        address controller; // 0 until the agent's B pool exists and deployController runs
        address creator;
        string name;
        string symbol;
    }

    Launch[] public launches;

    event TreasuryUpdated(address indexed treasury);
    event KycRegistryUpdated(address indexed registry);
    event ControllerFactoryUpdated(address indexed factory);
    event ControllerFactoryProposed(address indexed factory, uint256 effectiveAt);
    event ControllerActivated(uint256 indexed agentId, address indexed controller, uint256 totalB);
    event LauncherAuthorized(address indexed launcher, bool allowed);
    event PublicLaunchSet(bool enabled);
    event ControllerDeployed(uint256 indexed agentId, address indexed controller, address participationToken);
    event ControllerConfigured(
        uint256 indexed agentId, address indexed controller, address participationToken, address capexSink,
        address kyc, uint16 retainedBps, uint64 graceSeconds, uint64 cliffSeconds, uint64 vestSeconds
    );
    event ControllerBRecovered(uint256 indexed agentId, address indexed controller, uint256 amount);
    event ConfigProposed(bytes32 indexed key, address value, uint256 effectiveAt);
    event AgentLaunched(
        uint256 indexed agentId,
        address indexed token,
        address indexed curve,
        address creator,
        string name,
        string symbol
    );

    struct LaunchParams {
        string name;
        string symbol;
        uint256 supply;          // total share supply in WHOLE shares (minted x1e18)
        uint256 basePrice;       // quote base units per whole share at sold=0
        uint256 slope;           // quote base units added per whole share sold
        uint256 buyFeeBps;
        uint256 sellFeeBps;
        uint256 graduationRaise; // quote (net) that triggers curve → AMM graduation
        address creator;         // the agent's owner: beneficiary of the retained B (never the caller by default)
        address feeRecipient;    // curve trading fees (e.g. the agent's fee splitter); 0 ⇒ platformTreasury
    }

    modifier canLaunch() {
        require(publicLaunch || authorizedLauncher[msg.sender] || msg.sender == owner(), "not authorized");
        _;
    }

    constructor(address _owner, address _quoteToken, address _platformTreasury) Ownable(_owner) {
        require(_quoteToken != address(0) && _platformTreasury != address(0), "zero addr");
        quoteToken = IERC20(_quoteToken);
        platformTreasury = _platformTreasury;
        authorizedLauncher[_owner] = true;
        curveFactory = new AgentCurveFactory();
    }

    // ─── Admin ────────────────────────────────────────────────────────────────


    // Treasury and KYC registry changes are two-step with CONFIG_DELAY of public notice. The registry
    // can be set at once only before the first launch (fresh deployment wiring).
    address public pendingTreasury;
    uint256 public pendingTreasuryAt;
    address public pendingKycRegistry;
    uint256 public pendingKycRegistryAt;
    bool public kycRegistryPending;

    function setPlatformTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero addr");
        pendingTreasury = _treasury;
        pendingTreasuryAt = block.timestamp + CONFIG_DELAY;
        emit ConfigProposed("treasury", _treasury, pendingTreasuryAt);
    }

    function acceptPlatformTreasury() external onlyOwner {
        require(pendingTreasury != address(0), "none pending");
        require(block.timestamp >= pendingTreasuryAt, "timelocked");
        platformTreasury = pendingTreasury;
        pendingTreasury = address(0);
        emit TreasuryUpdated(platformTreasury);
    }

    /// @notice Set the KYC registry stamped into controllers deployed from here on.
    /// @dev Each {AgentController} holds its registry `immutable`, so this never retro-changes
    ///      the gate of an agent already deployed.
    function setKycRegistry(address _registry) external onlyOwner {
        if (launches.length == 0) {
            kycRegistry = IKycRegistry(_registry);
            emit KycRegistryUpdated(_registry);
            return;
        }
        pendingKycRegistry = _registry;
        pendingKycRegistryAt = block.timestamp + CONFIG_DELAY;
        kycRegistryPending = true;
        emit ConfigProposed("kyc", _registry, pendingKycRegistryAt);
    }

    function acceptKycRegistry() external onlyOwner {
        require(kycRegistryPending, "none pending");
        require(block.timestamp >= pendingKycRegistryAt, "timelocked");
        kycRegistry = IKycRegistry(pendingKycRegistry);
        kycRegistryPending = false;
        emit KycRegistryUpdated(pendingKycRegistry);
    }

    /// @notice Point at the factory that mints {AgentController} instances.
    /// @dev The first one applies at once (deployment). Replacing it is a two-step change with
    ///      FACTORY_DELAY of public notice: the factory decides the bytecode of every controller
    ///      deployed afterwards, so a swap must be visible before it can be used. It still only
    ///      reaches agents not yet bound — a curve honors the FIRST controller bound to it.
    function setControllerFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "zero addr");
        if (address(controllerFactory) == address(0)) {
            controllerFactory = AgentControllerFactory(_factory);
            emit ControllerFactoryUpdated(_factory);
            return;
        }
        pendingControllerFactory = _factory;
        pendingControllerFactoryAt = block.timestamp + FACTORY_DELAY;
        emit ControllerFactoryProposed(_factory, pendingControllerFactoryAt);
    }

    function acceptControllerFactory() external onlyOwner {
        require(pendingControllerFactory != address(0), "none pending");
        require(block.timestamp >= pendingControllerFactoryAt, "timelocked");
        controllerFactory = AgentControllerFactory(pendingControllerFactory);
        pendingControllerFactory = address(0);
        pendingControllerFactoryAt = 0;
        emit ControllerFactoryUpdated(address(controllerFactory));
    }

    function setAuthorizedLauncher(address launcher, bool allowed) external onlyOwner {
        authorizedLauncher[launcher] = allowed;
        emit LauncherAuthorized(launcher, allowed);
    }

    function setPublicLaunch(bool enabled) external onlyOwner {
        publicLaunch = enabled;
        emit PublicLaunchSet(enabled);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── Launch ───────────────────────────────────────────────────────────────

    function launch(LaunchParams calldata p)
        external
        whenNotPaused
        canLaunch
        returns (uint256 agentId, address token, address curve)
    {
        require(p.supply > 0 && p.basePrice > 0, "bad supply/price");
        require(p.buyFeeBps <= maxBuyFeeBps && p.sellFeeBps <= maxSellFeeBps, "fee too high");
        require(p.creator != address(0), "zero creator");
        _validateGraduation(p);
        address feeTo = p.feeRecipient == address(0) ? platformTreasury : p.feeRecipient;

        uint256 baseSupply = p.supply * 1e18;

        AgentShareToken share = new AgentShareToken(p.name, p.symbol, baseSupply, address(this), 18);

        AgentBondingCurve bondingCurve = AgentBondingCurve(curveFactory.deploy(AgentCurveFactory.Args({
            shareToken: address(share),
            quoteToken: address(quoteToken),
            basePrice: p.basePrice,
            slope: p.slope,
            sellFeeBps: p.sellFeeBps,
            buyFeeBps: p.buyFeeBps,
            graduationRaise: p.graduationRaise,
            curveSupply: p.supply,  // whole shares
            feeRecipient: feeTo
        })));

        IERC20(address(share)).safeTransfer(address(bondingCurve), baseSupply);

        agentId = launches.length;
        launches.push(Launch({
            token: address(share),
            curve: address(bondingCurve),
            controller: address(0),
            creator: p.creator,
            name: p.name,
            symbol: p.symbol
        }));

        emit AgentLaunched(agentId, address(share), address(bondingCurve), p.creator, p.name, p.symbol);
        return (agentId, address(share), address(bondingCurve));
    }

    // ─── The A→B crossing ─────────────────────────────────────────────────────

    struct ControllerParams {
        address participationToken; // Product B, issued by the agent's DobProtocol pool
        address capexSink;          // where released reserve goes to fund the real-world asset
        uint16 retainedBps;         // creator's share of B (100% − participation_to_sale)
        uint64 graceSeconds;        // conversion stays closed this long after activation
        uint64 cliffSeconds;        // retained B: nothing vests before this
        uint64 vestSeconds;         // retained B: linear over this window after the cliff
    }

    /**
     * @notice Deploy the {AgentController} for an agent and bind it to its curve — the step that
     *         turns a launched A market into a two-product agent.
     *
     * Runs after the DobProtocol pool has issued B, since the controller takes the participation
     * token as an immutable. Binding is one-shot in the curve, so this can only ever succeed
     * once per agent: there is no path to swap in a second controller later.
     *
     * The quote token is read off the CURVE (it is immutable here too; a new quote token means a
     * new launchpad). Before binding, B's supply must be fine enough for the crossing to ever
     * open: at least one B unit per whole A the curve could put in circulation, after retention.
     */
    function deployController(uint256 agentId, ControllerParams calldata p)
        external
        onlyOwner
        returns (address controller)
    {
        Launch storage l = launches[agentId];
        require(l.curve != address(0), "no agent");
        require(l.controller == address(0), "already deployed");
        require(p.participationToken != address(0) && p.capexSink != address(0), "zero addr");
        require(address(controllerFactory) != address(0), "no factory");
        require(p.retainedBps <= MAX_RETAINED_BPS, "retained too high");
        require(p.graceSeconds >= MIN_GRACE, "grace too short");
        require(p.graceSeconds <= MAX_GRACE && p.cliffSeconds <= MAX_CLIFF && p.vestSeconds <= MAX_VEST, "schedule too long");
        AgentBondingCurve c = AgentBondingCurve(l.curve);
        // B must be a token distinct from A and from the quote, and capex must leave the system.
        require(p.participationToken != l.token && p.participationToken != address(c.quoteToken()), "bad B");
        require(p.capexSink != l.curve && p.capexSink != address(this), "bad sink");
        uint256 bSupply = IERC20(p.participationToken).totalSupply();
        require(bSupply - (bSupply * p.retainedBps) / 10_000 >= c.curveSupply(), "B too coarse");

        controller = controllerFactory.deploy(AgentControllerFactory.Args({
            agentToken: l.token,
            participationToken: p.participationToken,
            quoteToken: address(c.quoteToken()),
            curve: l.curve,
            creator: l.creator,
            capexSink: p.capexSink,
            kyc: address(kycRegistry),
            activator: address(this),
            retainedBps: p.retainedBps,
            graceSeconds: p.graceSeconds,
            cliffSeconds: p.cliffSeconds,
            vestSeconds: p.vestSeconds
        }));
        c.bindController(controller);
        l.controller = controller;

        emit ControllerDeployed(agentId, controller, p.participationToken);
        emit ControllerConfigured(agentId, controller, p.participationToken, p.capexSink, address(kycRegistry),
            p.retainedBps, p.graceSeconds, p.cliffSeconds, p.vestSeconds);
        return controller;
    }

    /// @notice Return the B held by a controller that was never activated to the agent's creator.
    function recoverControllerB(uint256 agentId) external onlyOwner {
        address controller = launches[agentId].controller;
        require(controller != address(0), "no controller");
        uint256 amount = AgentController(controller).recoverB();
        emit ControllerBRecovered(agentId, controller, amount);
    }

    /**
     * @notice Open an agent's crossing: split `totalB` of the B its controller holds and start the
     *         grace and vesting clocks. Owner-only and once (the controller enforces both).
     */
    function activateController(uint256 agentId, uint256 totalB) external onlyOwner {
        address controller = launches[agentId].controller;
        require(controller != address(0), "no controller");
        AgentController(controller).activate(totalB);
        emit ControllerActivated(agentId, controller, totalB);
    }

    /// @dev Graduation must trigger with enough unsold A left to seed the AMM at the terminal
    ///      price. Finds the first sold count `n` whose raise meets the goal (the raise depends
    ///      only on `n`, and no pre-graduation path burns A) and requires the inventory left
    ///      there to cover `raise / price` — the same check the curve's graduating buy enforces.
    function _validateGraduation(LaunchParams calldata p) internal pure {
        require(p.supply > 1, "grad unreachable");
        uint256 lo = 1;
        uint256 hi = p.supply - 1;
        require(_raise(p, hi) >= p.graduationRaise, "grad unreachable");
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_raise(p, mid) >= p.graduationRaise) hi = mid; else lo = mid + 1;
        }
        require(_raise(p, lo) / (p.basePrice + lo * p.slope) <= p.supply - lo, "grad too late");
    }

    function _raise(LaunchParams calldata p, uint256 k) private pure returns (uint256) {
        return k * p.basePrice + (p.slope * (k - 1) * k) / 2;
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function launchesCount() external view returns (uint256) {
        return launches.length;
    }

    function getLaunch(uint256 agentId) external view returns (Launch memory) {
        return launches[agentId];
    }
}
