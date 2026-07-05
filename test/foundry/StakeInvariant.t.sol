// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../contracts/OperatorStake.sol";
import "../../contracts/mocks/MockUSDC.sol";

/// Randomly stakes / requests / withdraws / slashes / warps against the bond.
contract StakeHandler is Test {
    OperatorStake public stake;
    MockUSDC public usdc;

    constructor(MockUSDC _usdc) {
        usdc = _usdc;
        usdc.mint(address(this), type(uint96).max);
    }

    function setStake(OperatorStake _stake) external {
        stake = _stake;
        usdc.approve(address(stake), type(uint256).max);
    }

    function doStake(uint256 amt) external {
        amt = bound(amt, 1, 1_000_000e6);
        stake.stake(amt);
    }

    function doRequest() external {
        try stake.requestWithdraw() {} catch {}
    }

    function doWithdraw(uint256 amt) external {
        amt = bound(amt, 1, 1_000_000e6);
        try stake.withdraw(amt) {} catch {}
    }

    function doSlash(uint256 amt) external {
        amt = bound(amt, 1, 1_000_000e6);
        try stake.slash(amt, "fuzz") {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }
}

contract StakeInvariant is Test {
    OperatorStake stake;
    MockUSDC usdc;
    StakeHandler handler;
    address beneficiary = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        handler = new StakeHandler(usdc);
        // handler is both operator and attester so it can exercise every path
        stake = new OperatorStake(address(usdc), address(handler), address(handler), beneficiary, 7 days, address(this));
        handler.setStake(stake);
        targetContract(address(handler));
    }

    /// Accounting can never drift from the real balance: the contract holds exactly `staked`.
    function invariant_balanceEqualsStaked() public view {
        assertEq(usdc.balanceOf(address(stake)), stake.staked(), "balance != staked");
    }
}
