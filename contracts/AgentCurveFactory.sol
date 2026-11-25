// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AgentBondingCurve.sol";

/**
 * @title AgentCurveFactory
 * @notice Holds the creation code for {AgentBondingCurve} (which itself carries {AgentAMM}) so the
 *         launchpad's runtime stays under the 24 KB limit. A size split, like
 *         {AgentControllerFactory}, with one difference: it is created BY the launchpad in its
 *         constructor and only that launchpad may use it, so there is no factory address to set,
 *         swap or trust separately.
 */
contract AgentCurveFactory {
    address public immutable launchpad;

    struct Args {
        address shareToken;
        address quoteToken;
        uint256 basePrice;
        uint256 slope;
        uint256 sellFeeBps;
        uint256 buyFeeBps;
        uint256 graduationRaise;
        uint256 curveSupply;
        address feeRecipient;
    }

    constructor() {
        launchpad = msg.sender;
    }

    function deploy(Args calldata a) external returns (address) {
        require(msg.sender == launchpad, "not launchpad");
        return address(new AgentBondingCurve(
            a.shareToken, a.quoteToken, a.basePrice, a.slope, a.sellFeeBps, a.buyFeeBps,
            a.graduationRaise, a.curveSupply, a.feeRecipient, msg.sender
        ));
    }
}
