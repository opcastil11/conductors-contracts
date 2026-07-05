// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AgentTreasury.sol";
import "./AgentBuyback.sol";
import "./AgentConverter.sol";
import "./interfaces/IAgentAMM.sol";

/**
 * @title TokenomicsFactory
 * @notice Deploys and wires an agent's tokenomics trio in one call — {AgentTreasury},
 *         {AgentBuyback} and {AgentConverter} — once the two prerequisites exist:
 *           1. the agent's **AMM** (Product A's post-graduation market), and
 *           2. the agent's **distribution token B** (the DobProtocol participation token).
 *
 * These can't be deployed at the A-launch because the AMM only exists after the bonding curve
 * graduates and B is created in a separate DobProtocol flow. So the dobx backend calls this
 * factory afterwards, passing both, and persists the returned addresses in the registry.
 *
 * The trio is `owner`-controlled (the dobx backend / operator multisig). The owner still has to:
 *   - `AgentBuyback.setKeeper(cron)` — authorize the revenue-router cron to fire tranches;
 *   - fund the treasury's B reserve + point the revenue router at the buyback.
 */
contract TokenomicsFactory {
    struct BuybackThrottle {
        uint256 maxSpendPerEpoch; // USDC ceiling per epoch
        uint256 epochLength;      // seconds per epoch
        uint256 minInterval;      // min seconds between tranches
    }

    event TokenomicsDeployed(
        address indexed agentToken,
        address indexed amm,
        address indexed owner,
        address treasury,
        address buyback,
        address converter
    );

    /**
     * @param agentToken    Product A token
     * @param amm           the agent's AgentAMM (must trade `agentToken`)
     * @param distToken     Product B (DobProtocol participation token)
     * @param owner         controller of the trio (dobx backend / operator)
     * @param convertFeeBps A→USDC convert fee (bounded by AgentConverter.MAX_FEE_BPS)
     * @param throttle      buyback TWAP throttle
     */
    function deploy(
        address agentToken,
        address amm,
        address distToken,
        address owner,
        uint16 convertFeeBps,
        BuybackThrottle calldata throttle
    ) external returns (address treasury, address buyback, address converter) {
        require(
            agentToken != address(0) && amm != address(0) && distToken != address(0) && owner != address(0),
            "zero addr"
        );
        // The AMM must be A's market — otherwise buyback/converter would trade the wrong token.
        require(IAgentAMM(amm).shareToken() == agentToken, "amm/token mismatch");

        treasury = address(new AgentTreasury(agentToken, distToken, owner));
        buyback = address(
            new AgentBuyback(amm, treasury, owner, throttle.maxSpendPerEpoch, throttle.epochLength, throttle.minInterval)
        );
        converter = address(new AgentConverter(amm, treasury, convertFeeBps, owner));

        emit TokenomicsDeployed(agentToken, amm, owner, treasury, buyback, converter);
    }
}
