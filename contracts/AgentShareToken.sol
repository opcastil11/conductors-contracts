// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title AgentShareToken
 * @notice Product A — the tradeable ERC20 of a single dobx agent. Fixed supply, minted once to
 *         the bonding curve at launch, priced in DOBX.
 *
 * A does NOT receive distributions. Its link to the agent's real revenue is the RIGHT TO CONVERT
 * one-way into Product B (a DobProtocol future-revenue pool participation) — see
 * {AgentController} and docs/TOKENOMICS-V2.md §2/§3. That is what puts a floor under A
 * (`P_A ≥ P_B`, modulo the retention ratio and the DOBX/USDC leg) without A itself being a
 * cash-flow instrument.
 *
 * Deliberately minimal (no mint after launch, no owner, no upgrade) so the supply is fixed and
 * trust-minimized. `burn` is the ONE supply-side operation, and it only ever reduces supply: the
 * curve burns the A it receives from a conversion, which is what makes "el A convertido queda
 * inmovilizado" a verifiable fact rather than a promise.
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

    /// @notice Burn from the caller's own balance. Used by {AgentBondingCurve} on conversion.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
