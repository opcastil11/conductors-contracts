// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for Product B — the participation token a DobProtocol pool issues against a
///         future-revenue campaign. Mintable so tests can seed an {AgentController} with the
///         cap table the real pool would have issued to it.
contract MockParticipation is ERC20 {
    constructor() ERC20("Mock Participation", "BPART") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
