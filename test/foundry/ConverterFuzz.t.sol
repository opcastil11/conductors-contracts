// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../contracts/AgentConverter.sol";
import "../../contracts/AgentAMM.sol";
import "../../contracts/AgentShareToken.sol";
import "../../contracts/mocks/MockUSDC.sol";

/// Property fuzzing of the A→USDC convert (fee conservation).
contract ConverterFuzz is Test {
    AgentAMM amm;
    AgentShareToken share;
    MockUSDC usdc;
    address treasury = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        share = new AgentShareToken("A", "A", 1_000_000_000e18, address(this), 18);
        amm = new AgentAMM(address(share), address(usdc));
        usdc.mint(address(this), 1_000_000e6);
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.addLiquidity(500_000e18, 500_000e6, 0, 0, block.timestamp);
    }

    /// gross = fee + net exactly; fee is bounded by the fee bps; nothing sticks to the converter.
    function testFuzz_convertConservesValue(uint256 feeBps, uint256 aIn) public {
        feeBps = bound(feeBps, 0, 200); // MAX_FEE_BPS
        aIn = bound(aIn, 1e16, 50_000e18); // ≥0.01 share so the AMM yields > 0 USDC out

        AgentConverter conv = new AgentConverter(address(amm), treasury, uint16(feeBps), address(this));

        // give a fresh user the A and convert on their behalf
        address user = address(0xCAFE);
        share.transfer(user, aIn);
        vm.startPrank(user);
        share.approve(address(conv), aIn);
        uint256 net = conv.convert(aIn, 0, block.timestamp);
        vm.stopPrank();

        uint256 userGot = usdc.balanceOf(user);
        uint256 treasuryGot = usdc.balanceOf(treasury);
        uint256 gross = userGot + treasuryGot;

        assertEq(userGot, net, "return value != USDC received");
        assertEq(treasuryGot, (gross * feeBps) / 10_000, "fee mismatch");
        assertEq(userGot + treasuryGot, gross, "value not conserved");
        assertLe(treasuryGot, (gross * 200) / 10_000, "fee exceeds MAX_FEE_BPS");
        assertEq(usdc.balanceOf(address(conv)), 0, "USDC stuck in converter");
        assertEq(share.balanceOf(address(conv)), 0, "A stuck in converter");
    }
}
