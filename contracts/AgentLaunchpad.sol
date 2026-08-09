// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./AgentShareToken.sol";
import "./AgentBondingCurve.sol";
import "./AgentControllerFactory.sol";

/**
 * @title AgentLaunchpad
 * @notice Factory + registry for dobx agent fair launches (Product A). Each launch deploys an
 *         {AgentShareToken} (fixed supply) + an {AgentBondingCurve} quoted in DOBX, mints the
 *         supply into the curve, validates the economics, and records the trio. Once the agent's
 *         DobProtocol pool exists, {deployController} attaches the {AgentController} that owns
 *         the A→B crossing.
 *
 * Security-hardened vs the initial draft (audit fixes):
 *  - **Gated launches**: `launch()` is restricted to authorized launchers (the dobx backend /
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
    IERC20 public quoteToken;
    address public platformTreasury;  // fee recipient + leftover-A treasury
    IKycRegistry public kycRegistry;  // gate applied at the A→B crossing; 0 ⇒ ungated (testnet)
    AgentControllerFactory public controllerFactory; // holds AgentController's creation code (size split)
    uint16 public maxBuyFeeBps = 500;  // 5%
    uint16 public maxSellFeeBps = 500; // 5%
    bool public publicLaunch;          // if false, only authorized launchers may launch
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

    event QuoteTokenUpdated(address indexed quoteToken);
    event TreasuryUpdated(address indexed treasury);
    event KycRegistryUpdated(address indexed registry);
    event ControllerFactoryUpdated(address indexed factory);
    event LauncherAuthorized(address indexed launcher, bool allowed);
    event PublicLaunchSet(bool enabled);
    event ControllerDeployed(uint256 indexed agentId, address indexed controller, address participationToken);
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
        uint256 basePrice;       // USDC base units per whole share at sold=0
        uint256 slope;           // USDC base units added per whole share sold
        uint256 buyFeeBps;
        uint256 sellFeeBps;
        uint256 graduationRaise; // USDC (net) that triggers curve → AMM graduation
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
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setQuoteToken(address _quoteToken) external onlyOwner {
        require(_quoteToken != address(0), "zero addr");
        quoteToken = IERC20(_quoteToken);
        emit QuoteTokenUpdated(_quoteToken);
    }

    function setPlatformTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero addr");
        platformTreasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @notice Set the KYC registry stamped into controllers deployed from here on.
    /// @dev Each {AgentController} holds its registry `immutable`, so this never retro-changes
    ///      the gate of an agent already deployed.
    function setKycRegistry(address _registry) external onlyOwner {
        kycRegistry = IKycRegistry(_registry);
        emit KycRegistryUpdated(_registry);
    }

    /// @notice Point at the factory that mints {AgentController} instances.
    /// @dev Only affects agents that have not been bound yet — a curve honors the FIRST
    ///      controller bound to it and refuses every later one, so re-pointing this cannot reach
    ///      an agent whose crossing is already live.
    function setControllerFactory(address _factory) external onlyOwner {
        controllerFactory = AgentControllerFactory(_factory);
        emit ControllerFactoryUpdated(_factory);
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
        _validateGraduation(p);

        uint256 baseSupply = p.supply * 1e18;

        AgentShareToken share = new AgentShareToken(p.name, p.symbol, baseSupply, address(this), 18);

        AgentBondingCurve bondingCurve = new AgentBondingCurve(
            address(share),
            address(quoteToken),
            p.basePrice,
            p.slope,
            p.sellFeeBps,
            p.buyFeeBps,
            p.graduationRaise,
            p.supply,           // curveSupply (whole shares)
            platformTreasury,   // feeRecipient
            platformTreasury    // treasury (leftover A)
        );

        IERC20(address(share)).safeTransfer(address(bondingCurve), baseSupply);

        agentId = launches.length;
        launches.push(Launch({
            token: address(share),
            curve: address(bondingCurve),
            controller: address(0),
            creator: msg.sender,
            name: p.name,
            symbol: p.symbol
        }));

        emit AgentLaunched(agentId, address(share), address(bondingCurve), msg.sender, p.name, p.symbol);
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
     * The quote token is read off the CURVE, not from this contract's current setting, so an
     * agent launched before a {setQuoteToken} switch still gets a controller wired to the token
     * its own curve actually holds.
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

        AgentBondingCurve c = AgentBondingCurve(l.curve);
        controller = controllerFactory.deploy(AgentControllerFactory.Args({
            agentToken: l.token,
            participationToken: p.participationToken,
            quoteToken: address(c.quoteToken()),
            curve: l.curve,
            creator: l.creator,
            capexSink: p.capexSink,
            kyc: address(kycRegistry),
            retainedBps: p.retainedBps,
            graceSeconds: p.graceSeconds,
            cliffSeconds: p.cliffSeconds,
            vestSeconds: p.vestSeconds
        }));
        c.bindController(controller);
        l.controller = controller;

        emit ControllerDeployed(agentId, controller, p.participationToken);
        return controller;
    }

    /// @dev Ensure graduation is reachable before the curve sells out (leaving inventory to seed
    ///      the AMM). The curve itself clamps the seed to a valid range, so no tight lower bound
    ///      is needed here — only that graduation triggers before the full integral is raised.
    function _validateGraduation(LaunchParams calldata p) internal pure {
        uint256 fullIntegral = p.supply * p.basePrice + (p.slope * (p.supply - 1) * p.supply) / 2;
        require(p.graduationRaise < fullIntegral, "grad unreachable");
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function launchesCount() external view returns (uint256) {
        return launches.length;
    }

    function getLaunch(uint256 agentId) external view returns (Launch memory) {
        return launches[agentId];
    }
}
