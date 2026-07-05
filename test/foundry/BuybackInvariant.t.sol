// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../contracts/AgentBuyback.sol";
import "../../contracts/AgentTreasury.sol";
import "../../contracts/AgentAMM.sol";
import "../../contracts/AgentShareToken.sol";
import "../../contracts/mocks/MockUSDC.sol";

/// Randomly funds the buyback, fires tranches (as keeper), and warps time.
contract BuybackHandler is Test {
    AgentBuyback public bb;
    AgentAMM public amm;
    AgentShareToken public share;
    MockUSDC public usdc;
    address public treasury;
    uint256 public treasuryFloor;

    constructor(AgentBuyback _bb, AgentAMM _amm, AgentShareToken _share, MockUSDC _usdc, address _treasury) {
        bb = _bb; amm = _amm; share = _share; usdc = _usdc; treasury = _treasury;
        usdc.mint(address(this), type(uint96).max);
        usdc.approve(address(bb), type(uint256).max);
    }

    function fund(uint256 amt) external {
        amt = bound(amt, 1, usdc.balanceOf(address(this)));
        bb.deposit(amt);
    }

    function execute(uint256 amt) external {
        amt = bound(amt, 1, 2_000e6);
        try bb.executeBuyback(amt, 0, block.timestamp) {
            uint256 t = share.balanceOf(treasury);
            if (t > treasuryFloor) treasuryFloor = t;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 7200));
    }
}

contract BuybackInvariant is Test {
    AgentBuyback bb;
    AgentTreasury treasury;
    AgentAMM amm;
    AgentShareToken share;
    AgentShareToken distB;
    MockUSDC usdc;
    BuybackHandler handler;

    function setUp() public {
        usdc = new MockUSDC();
        share = new AgentShareToken("A", "A", 1_000_000_000e18, address(this), 18);
        distB = new AgentShareToken("B", "B", 1_000_000e18, address(this), 18);

        amm = new AgentAMM(address(share), address(usdc));
        usdc.mint(address(this), 1_000_000e6);
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.addLiquidity(500_000e18, 500_000e6, 0, 0, block.timestamp);

        treasury = new AgentTreasury(address(share), address(distB), address(this));

        // maxSpendPerEpoch = 1000 USDC, epoch 3600s, minInterval 60s
        bb = new AgentBuyback(address(amm), address(treasury), address(this), 1_000e6, 3600, 60);

        handler = new BuybackHandler(bb, amm, share, usdc, address(treasury));
        bb.setKeeper(address(handler));

        targetContract(address(handler));
    }

    /// The per-epoch spend ceiling is never exceeded.
    function invariant_epochCapRespected() public view {
        assertLe(bb.spentThisEpoch(), bb.maxSpendPerEpoch(), "epoch cap breached");
    }

    /// The buyback forwards every bought A to the treasury — it never accumulates A itself.
    function invariant_buybackHoldsNoA() public view {
        assertEq(share.balanceOf(address(bb)), 0, "buyback is holding A");
    }

    /// Treasury A is monotonically non-decreasing (no path out of the treasury for A).
    function invariant_treasuryAMonotonic() public view {
        assertGe(share.balanceOf(address(treasury)), handler.treasuryFloor(), "treasury A dropped");
    }
}
