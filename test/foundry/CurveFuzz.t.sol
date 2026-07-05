// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../contracts/AgentBondingCurve.sol";
import "../../contracts/AgentShareToken.sol";
import "../../contracts/mocks/MockUSDC.sol";

/// Property fuzzing of the per-whole-share bonding-curve arithmetic.
contract CurveFuzz is Test {
    MockUSDC usdc;
    address treasury = address(0xdEaD);
    address fees = address(0xBEEF);
    uint256 constant NO_GRAD = type(uint128).max; // huge → buys never trigger graduation here

    function setUp() public {
        usdc = new MockUSDC();
    }

    function _deploy(uint256 base, uint256 slope, uint256 buyFee, uint256 sellFee, uint256 supply)
        internal
        returns (AgentBondingCurve curve)
    {
        AgentShareToken a = new AgentShareToken("A", "A", supply * 1e18, address(this), 18);
        curve = new AgentBondingCurve(
            address(a), address(usdc), base, slope, sellFee, buyFee, NO_GRAD, supply, fees, treasury
        );
        a.transfer(address(curve), supply * 1e18);
        usdc.mint(address(this), type(uint128).max);
        usdc.approve(address(curve), type(uint256).max);
        a.approve(address(curve), type(uint256).max);
    }

    /// Splitting a buy must cost exactly the same as buying the whole in one shot (no free shares
    /// or hidden discount from rounding). Fees off to isolate the pricing integral.
    function testFuzz_buyIsAdditive(uint256 base, uint256 slope, uint256 k1, uint256 k2) public {
        base = bound(base, 1, 1e9);
        slope = bound(slope, 0, 1e6);
        k1 = bound(k1, 1, 4000);
        k2 = bound(k2, 1, 4000);
        uint256 supply = k1 + k2 + 2; // buy cap is strict `<`, leave headroom

        // one shot
        AgentBondingCurve c1 = _deploy(base, slope, 0, 0, supply);
        uint256 before1 = usdc.balanceOf(address(this));
        c1.buy(k1 + k2, type(uint256).max, block.timestamp);
        uint256 spentOne = before1 - usdc.balanceOf(address(this));

        // split
        AgentBondingCurve c2 = _deploy(base, slope, 0, 0, supply);
        uint256 before2 = usdc.balanceOf(address(this));
        c2.buy(k1, type(uint256).max, block.timestamp);
        c2.buy(k2, type(uint256).max, block.timestamp);
        uint256 spentSplit = before2 - usdc.balanceOf(address(this));

        assertEq(spentSplit, spentOne, "split buy != single buy");
        assertEq(c1.sold(), c2.sold(), "sold mismatch");
    }

    /// An instant buy-then-sell round trip can never profit (fees + neutral pricing guarantee it).
    function testFuzz_roundTripNeverProfits(
        uint256 base, uint256 slope, uint256 k, uint256 buyFee, uint256 sellFee
    ) public {
        base = bound(base, 1, 1e9);
        slope = bound(slope, 0, 1e6);
        k = bound(k, 1, 4000);
        buyFee = bound(buyFee, 0, 1000);
        sellFee = bound(sellFee, 0, 1000);
        uint256 supply = k + 2;

        AgentBondingCurve curve = _deploy(base, slope, buyFee, sellFee, supply);

        uint256 beforeBuy = usdc.balanceOf(address(this));
        curve.buy(k, type(uint256).max, block.timestamp);
        uint256 costTotal = beforeBuy - usdc.balanceOf(address(this));

        uint256 beforeSell = usdc.balanceOf(address(this));
        curve.sell(k, 0, block.timestamp);
        uint256 proceeds = usdc.balanceOf(address(this)) - beforeSell;

        assertLe(proceeds, costTotal, "round trip profited");
        assertEq(curve.sold(), 0, "sold not restored");
    }

    /// Price is a pure, monotonically non-decreasing function of `sold`.
    function testFuzz_priceMonotonic(uint256 base, uint256 slope, uint256 k) public {
        base = bound(base, 1, 1e9);
        slope = bound(slope, 1, 1e6);
        k = bound(k, 1, 4000);
        AgentBondingCurve curve = _deploy(base, slope, 0, 0, k + 2);

        uint256 p0 = curve.getCurrentPrice();
        curve.buy(k, type(uint256).max, block.timestamp);
        uint256 p1 = curve.getCurrentPrice();

        assertEq(p0, base, "start price != base");
        assertEq(p1, base + k * slope, "price != base + sold*slope");
        assertGe(p1, p0, "price decreased");
    }
}
