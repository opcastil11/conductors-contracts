// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./AgentShareToken.sol";
import "./AgentBondingCurve.sol";

/**
 * @title AgentLaunchpad
 * @notice Factory + registry for dobx agent fair launches (Product A). Each launch deploys an
 *         {AgentShareToken} (fixed supply) + an {AgentBondingCurve}, mints the supply into the
 *         curve, validates the economics, and records the trio.
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

    IERC20 public quoteToken;         // USDC
    address public platformTreasury;  // fee recipient + leftover-A treasury
    uint16 public maxBuyFeeBps = 500;  // 5%
    uint16 public maxSellFeeBps = 500; // 5%
    bool public publicLaunch;          // if false, only authorized launchers may launch
    mapping(address => bool) public authorizedLauncher;

    struct Launch {
        address token;
        address curve;
        address creator;
        string name;
        string symbol;
    }

    Launch[] public launches;

    event QuoteTokenUpdated(address indexed quoteToken);
    event TreasuryUpdated(address indexed treasury);
    event LauncherAuthorized(address indexed launcher, bool allowed);
    event PublicLaunchSet(bool enabled);
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
            creator: msg.sender,
            name: p.name,
            symbol: p.symbol
        }));

        emit AgentLaunched(agentId, address(share), address(bondingCurve), msg.sender, p.name, p.symbol);
        return (agentId, address(share), address(bondingCurve));
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
