// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../contracts/AgentAMM.sol";
import "../../contracts/AgentShareToken.sol";
import "../../contracts/mocks/MockUSDC.sol";

/// Drives random swaps + donations against a seeded AMM.
contract AMMHandler is Test {
    AgentAMM public amm;
    AgentShareToken public share;
    MockUSDC public usdc;

    constructor(AgentAMM _amm, AgentShareToken _share, MockUSDC _usdc) {
        amm = _amm; share = _share; usdc = _usdc;
        // fund USDC + approve both so the handler can trade/donate freely (share inventory is
        // transferred in by the test after construction).
        usdc.mint(address(this), type(uint96).max);
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
    }

    function swapAtoQ(uint256 amt) external {
        amt = bound(amt, 1, share.balanceOf(address(this)));
        amm.swapShareForQuote(amt, 0, block.timestamp);
    }

    function swapQtoA(uint256 amt) external {
        amt = bound(amt, 1, usdc.balanceOf(address(this)));
        amm.swapQuoteForShare(amt, 0, block.timestamp);
    }

    // Donations must NOT move price or internal reserves (explicit-reserve accounting).
    function donateA(uint256 amt) external {
        amt = bound(amt, 0, share.balanceOf(address(this)));
        share.transfer(address(amm), amt);
    }

    function donateQ(uint256 amt) external {
        amt = bound(amt, 0, usdc.balanceOf(address(this)));
        usdc.transfer(address(amm), amt);
    }
}

contract AMMInvariant is Test {
    AgentAMM amm;
    AgentShareToken share;
    MockUSDC usdc;
    AMMHandler handler;

    uint256 k0;
    uint256 liq0;

    function setUp() public {
        usdc = new MockUSDC();
        share = new AgentShareToken("A", "A", 1_000_000_000e18, address(this), 18);

        amm = new AgentAMM(address(share), address(usdc));
        // seed a healthy pool
        usdc.mint(address(this), 1_000_000e6);
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.addLiquidity(500_000e18, 500_000e6, 0, 0, block.timestamp);

        k0 = amm.shareReserve() * amm.quoteReserve();
        liq0 = amm.totalLiquidity();

        // hand a big share inventory to the handler so it can trade both directions
        handler = new AMMHandler(amm, share, usdc);
        share.transfer(address(handler), 100_000_000e18);

        targetContract(address(handler));
    }

    /// Internal reserves can never exceed the real token balances — donating tokens to the pool
    /// can't inflate accounting (no first-depositor / donation price manipulation).
    function invariant_reservesBackedByBalances() public view {
        assertLe(amm.shareReserve(), share.balanceOf(address(amm)), "share reserve > balance");
        assertLe(amm.quoteReserve(), usdc.balanceOf(address(amm)), "quote reserve > balance");
    }

    /// Swaps only ever grow k (0.3% fee); with no liquidity removed, k never drops below the seed.
    function invariant_kNeverDecreases() public view {
        uint256 k = amm.shareReserve() * amm.quoteReserve();
        assertGe(k, k0, "k dropped below seed");
    }

    /// Swaps and donations mint/burn no LP.
    function invariant_liquidityConstant() public view {
        assertEq(amm.totalLiquidity(), liq0, "LP supply changed on swap/donate");
    }
}
