// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AgentController.sol";

/**
 * @title AgentControllerFactory
 * @notice Holds the creation code for {AgentController} so {AgentLaunchpad} does not have to.
 *
 * Purely a size split: with the curve's creation bytecode (which itself carries {AgentAMM}) AND
 * the controller's inlined, the launchpad compiled to ~29.5 KB and could not be deployed under
 * the Spurious Dragon 24 KB limit. Moving one of the two out is the standard remedy; nothing
 * about the model changes.
 *
 * This contract has no owner, no state, and holds no funds — `deploy` is permissionless and its
 * only effect is to `new` a controller with the arguments it was handed. Trust does not rest
 * here: the launchpad chooses the arguments, and {AgentBondingCurve-bindController} — callable
 * only by the launchpad, only once per curve — decides which controller a curve will ever honor.
 * A controller from an unblessed factory is simply an unbound contract with no powers.
 */
contract AgentControllerFactory {
    event ControllerCreated(address indexed controller, address indexed agentToken, address participationToken);

    struct Args {
        address agentToken;
        address participationToken;
        address quoteToken;
        address curve;
        address creator;
        address capexSink;
        address kyc;
        uint16 retainedBps;
        uint64 graceSeconds;
        uint64 cliffSeconds;
        uint64 vestSeconds;
    }

    function deploy(Args calldata a) external returns (address controller) {
        AgentController c = new AgentController(
            a.agentToken,
            a.participationToken,
            a.quoteToken,
            a.curve,
            a.creator,
            a.capexSink,
            a.kyc,
            a.retainedBps,
            a.graceSeconds,
            a.cliffSeconds,
            a.vestSeconds
        );
        emit ControllerCreated(address(c), a.agentToken, a.participationToken);
        return address(c);
    }
}
