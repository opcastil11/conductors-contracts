// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./AgentShareToken.sol";
import "./AgentBondingCurve.sol";

/**
 * @title AgentLaunchpad
 * @notice Factory + registry for dobx agent fair launches. Each launch deploys an
 *         {AgentShareToken} (fixed supply) and an {AgentBondingCurve}, mints the whole
 *         supply into the curve, and records the trio. Off-chain, the dobx backend calls
 *         this for the operator whose DOBI asset is being tokenized; on-chain it is
 *         permissionless, with `creator` recorded as the caller.
 *
 * The quote token (USDC) and the platform treasury (which receives buy fees and, after
 * graduation, holds the locked LP position via the curve) are set by the owner.
 */
contract AgentLaunchpad is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public quoteToken;         // USDC
    address public platformTreasury;  // fee recipient
    uint16 public maxBuyFeeBps = 500;  // 5% cap
    uint16 public maxSellFeeBps = 500; // 5% cap

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
        uint256 buyFeeBps;       // fee to platform treasury on buys
        uint256 sellFeeBps;      // fee retained by the pool on sells
        uint256 graduationRaise; // USDC (net) that triggers curve → AMM graduation
    }

    constructor(address _owner, address _quoteToken, address _platformTreasury) Ownable(_owner) {
        require(_quoteToken != address(0) && _platformTreasury != address(0), "zero addr");
        quoteToken = IERC20(_quoteToken);
        platformTreasury = _platformTreasury;
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

    // ─── Launch ───────────────────────────────────────────────────────────────

    /// @notice Deploy a new agent (share token + bonding curve) and register it.
    function launch(LaunchParams calldata p) external returns (uint256 agentId, address token, address curve) {
        require(p.supply > 0, "supply>0");
        require(p.buyFeeBps <= maxBuyFeeBps && p.sellFeeBps <= maxSellFeeBps, "fee too high");

        uint256 baseSupply = p.supply * 1e18;

        // 1. mint the whole supply to this factory
        AgentShareToken share = new AgentShareToken(p.name, p.symbol, baseSupply, address(this), 18);

        // 2. deploy the curve (fees route to the platform treasury)
        AgentBondingCurve bondingCurve = new AgentBondingCurve(
            address(share),
            address(quoteToken),
            p.basePrice,
            p.slope,
            p.sellFeeBps,
            p.buyFeeBps,
            p.graduationRaise,
            platformTreasury
        );

        // 3. move the supply into the curve so it can sell + later seed the AMM
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

    // ─── Views ────────────────────────────────────────────────────────────────

    function launchesCount() external view returns (uint256) {
        return launches.length;
    }

    function getLaunch(uint256 agentId) external view returns (Launch memory) {
        return launches[agentId];
    }
}
