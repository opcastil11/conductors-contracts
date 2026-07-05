// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title AgentShareToken
 * @notice The tradeable ERC20 that represents shares of a single dobx agent (a real-world
 *         asset operated in DOBI). Fixed supply, minted once to the bonding curve at launch.
 *
 * The same balances are what DobProtocol's distribution reads to pay out the agent's real
 * revenue (yield) to holders — so holding this token is both a market position AND a claim
 * on the asset's cash flow. This contract stays deliberately minimal (no mint after launch,
 * no owner) so the supply is fixed and trust-minimized.
 */
contract AgentShareToken is ERC20 {
    uint8 private immutable _decimals;

    /**
     * @param name_        e.g. "Providencia EV Hub"
     * @param symbol_      e.g. "PROV"
     * @param supply_      total fixed supply (in token base units), all minted to `mintTo`
     * @param mintTo       recipient of the entire supply (the bonding curve)
     * @param decimals_    token decimals (18 by convention)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address mintTo,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        require(mintTo != address(0), "mintTo=0");
        require(supply_ > 0, "supply=0");
        _decimals = decimals_;
        _mint(mintTo, supply_);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
