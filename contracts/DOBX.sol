// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title DOBX
 * @notice The dobx platform token — the QUOTE TOKEN of every agent bonding curve and AMM
 *         (docs/TOKENOMICS-V2.md §2, "modelo Virtuals").
 *
 * Every agent launch prices Product A in DOBX, so buying into any agent is a DOBX sink and the
 * platform token accrues the aggregate demand of the launchpad rather than sitting beside it.
 *
 * Deliberately minimal and trust-minimized, exactly like {AgentShareToken}:
 *  - **Fixed supply**, minted once at deploy. There is no `mint`, no owner, no pauser, no
 *    blocklist, and no upgrade path. Nothing about this contract can change after deploy.
 *  - `burn`/`burnFrom` exist so supply can only ever go DOWN (the curve burns its own DOBX
 *    holdings in no path today, but holders and future sinks can).
 *
 * WHY 18 decimals: {AgentBondingCurve} prices per WHOLE share in quote base units, and the
 * launch params (basePrice/slope) are integers in those base units. With 18dp a slope of 1 base
 * unit is 1e-18 DOBX/share — far finer than the 1e-6 floor MockUSDC imposed, so the terminal
 * price is exactly representable for any curve the calibrator picks (§3.4 rationality bound).
 *
 * NOTE (open item, §4.2 of TOKENOMICS-V2): because the curve reserve is denominated in DOBX,
 * the capex released by a conversion is DOBX, and funding a physical asset means selling it.
 * That tension is economic and lives outside this contract; nothing here mitigates it.
 */
contract DOBX is ERC20 {
    /// @notice Total supply, minted once at deploy. 1,000,000,000 DOBX.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    /**
     * @param treasury receives the entire supply; distribution/vesting is handled off-contract
     *                 so this token stays free of privileged roles.
     */
    constructor(address treasury) ERC20("dobx", "DOBX") {
        require(treasury != address(0), "treasury=0");
        _mint(treasury, INITIAL_SUPPLY);
    }

    /// @notice Burn from the caller's own balance. Supply is monotonically non-increasing.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burn from `from`, spending the caller's allowance.
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
