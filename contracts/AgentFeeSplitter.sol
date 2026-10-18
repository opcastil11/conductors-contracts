// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgentFeeSplitter
 * @notice The `feeRecipient` of one agent's bonding curve. A's trading fees (1% buy / 1% sell, in
 *         the quote token) land here and are split between the **agent's wallet** — which pays its
 *         own compute out of them — and the **platform**. Default 65% agent / 35% platform.
 *
 * The curve's `feeRecipient` is immutable, so the ratio lives here instead: the owner (the
 * platform) can move it within [MIN_AGENT_BPS, 10000] and re-point the platform payee; the agent
 * payee can be rotated by the agent itself or by the owner (the agent's custodied wallet may be
 * replaced). `release` is permissionless — anyone can push the accrued balance out at the ratio in
 * force at that moment.
 *
 * The curve also sends its leftover A to the same address it uses as treasury; any token other
 * than the quote token is not a fee and goes to the platform whole.
 */
contract AgentFeeSplitter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MIN_AGENT_BPS = 5000; // the agent never gets less than half its fees

    IERC20 public immutable quoteToken;
    address public agent;
    address public platform;
    uint16 public agentBps;

    event Released(address indexed token, uint256 toAgent, uint256 toPlatform);
    event AgentBpsUpdated(uint16 agentBps);
    event AgentUpdated(address indexed agent);
    event PlatformUpdated(address indexed platform);

    constructor(address _quoteToken, address _agent, address _platform, uint16 _agentBps, address _owner)
        Ownable(_owner)
    {
        require(_quoteToken != address(0) && _agent != address(0) && _platform != address(0), "zero addr");
        require(_agentBps >= MIN_AGENT_BPS && _agentBps <= 10000, "bad bps");
        quoteToken = IERC20(_quoteToken);
        agent = _agent;
        platform = _platform;
        agentBps = _agentBps;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setAgentBps(uint16 _agentBps) external onlyOwner {
        require(_agentBps >= MIN_AGENT_BPS && _agentBps <= 10000, "bad bps");
        agentBps = _agentBps;
        emit AgentBpsUpdated(_agentBps);
    }

    function setPlatform(address _platform) external onlyOwner {
        require(_platform != address(0), "zero addr");
        platform = _platform;
        emit PlatformUpdated(_platform);
    }

    function setAgent(address _agent) external {
        require(msg.sender == agent || msg.sender == owner(), "not agent/owner");
        require(_agent != address(0), "zero addr");
        agent = _agent;
        emit AgentUpdated(_agent);
    }

    // ─── Release ──────────────────────────────────────────────────────────────

    /// @notice Push this contract's whole balance of `token` out. Quote token: split agent/platform
    ///         at the current ratio. Anything else: all to the platform.
    function release(IERC20 token) public nonReentrant returns (uint256 toAgent, uint256 toPlatform) {
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) return (0, 0);
        if (address(token) == address(quoteToken)) {
            toAgent = (bal * agentBps) / 10000;
            toPlatform = bal - toAgent;
            if (toAgent > 0) token.safeTransfer(agent, toAgent);
        } else {
            toPlatform = bal;
        }
        if (toPlatform > 0) token.safeTransfer(platform, toPlatform);
        emit Released(address(token), toAgent, toPlatform);
    }

    /// @notice What `release(quoteToken)` would pay right now.
    function pending() external view returns (uint256 toAgent, uint256 toPlatform) {
        uint256 bal = quoteToken.balanceOf(address(this));
        toAgent = (bal * agentBps) / 10000;
        toPlatform = bal - toAgent;
    }
}
