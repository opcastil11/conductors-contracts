// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentTreasury
 * @notice Per-agent treasury (see docs/TOKENOMICS.md). Two roles:
 *
 *  1. **Sink for the agent token A** — the buyback repurchases A and sends it here. A has
 *     **no path out** of this contract, so repurchased A is permanently retired: it can never
 *     be dumped back on holders. This is the non-negotiable anti-dump invariant.
 *
 *  2. **Strategic reserve of the distribution token B** — at launch the agent allocates a
 *     reserve of B (⚙️ ~50% of supply) here. Unlike A, B is **owner-deployable**: the treasury
 *     can list part of the reserve on the DobProtocol marketplace to backstop the A→B convert
 *     flow (guarantee there is always B to buy) or use it for incentives. Deploying B makes it
 *     circulate and therefore dilutes per-token yield, so it is a **disclosed governance lever**,
 *     gated by `onlyOwner` and logged.
 *
 * Any other token (USDC conversion fees, misc.) is also owner-deployable. Only **A is locked**.
 */
contract AgentTreasury is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable agentToken; // A — accumulates here, permanently non-sellable
    IERC20 public immutable distToken;  // B — strategic/backstop reserve, owner-deployable

    event Deployed(address indexed token, address indexed to, uint256 amount);

    constructor(address _agentToken, address _distToken, address _owner) Ownable(_owner) {
        require(_agentToken != address(0) && _distToken != address(0), "zero token");
        require(_agentToken != _distToken, "same token");
        agentToken = IERC20(_agentToken);
        distToken = IERC20(_distToken);
    }

    /**
     * @notice Move any treasury token EXCEPT the locked agent token A. Used to list the B reserve
     *         on the marketplace (convert-flow backstop), pay incentives, or route USDC fees.
     * @dev Reverts for A — repurchased A can never leave the treasury.
     */
    function deploy(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(agentToken), "agent token locked");
        require(to != address(0) && amount > 0, "bad args");
        IERC20(token).safeTransfer(to, amount);
        emit Deployed(token, to, amount);
    }

    function agentHeld() external view returns (uint256) {
        return agentToken.balanceOf(address(this));
    }

    function distHeld() external view returns (uint256) {
        return distToken.balanceOf(address(this));
    }
}
