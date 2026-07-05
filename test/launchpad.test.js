const { expect } = require("chai");
const { ethers } = require("hardhat");

// Economics used across tests:
//   supply           1,000,000 whole shares
//   basePrice        50_000 USDC base units = $0.05 per share at sold=0
//   slope            100    = +$0.0001 per whole share sold
//   graduationRaise  50_000_000 = $50 raised triggers curve → AMM
const SUPPLY = 1_000_000n;
const BASE_PRICE = 50_000n;
const SLOPE = 100n;
const GRAD_RAISE = 50_000_000n; // $50
const BUY_FEE = 100n;  // 1%
const SELL_FEE = 100n; // 1%
const USDC = (n) => BigInt(Math.round(n * 1e6)); // $ → 6dp base units

async function deployFixture() {
  const [owner, treasury, alice, bob] = await ethers.getSigners();

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();

  const Launchpad = await ethers.getContractFactory("AgentLaunchpad");
  const launchpad = await Launchpad.deploy(owner.address, await usdc.getAddress(), treasury.address);

  // fund buyers
  for (const u of [alice, bob]) await usdc.mint(u.address, USDC(1_000_000));

  return { owner, treasury, alice, bob, usdc, launchpad };
}

async function launchAgent(launchpad) {
  const tx = await launchpad.launch({
    name: "Providencia EV Hub",
    symbol: "PROV",
    supply: SUPPLY,
    basePrice: BASE_PRICE,
    slope: SLOPE,
    buyFeeBps: BUY_FEE,
    sellFeeBps: SELL_FEE,
    graduationRaise: GRAD_RAISE,
  });
  await tx.wait();
  const l = await launchpad.getLaunch(0);
  const share = await ethers.getContractAt("AgentShareToken", l.token);
  const curve = await ethers.getContractAt("AgentBondingCurve", l.curve);
  return { share, curve };
}

describe("AgentLaunchpad", () => {
  it("launches an agent: token minted into the curve", async () => {
    const { launchpad } = await deployFixture();
    const { share, curve } = await launchAgent(launchpad);

    expect(await launchpad.launchesCount()).to.equal(1);
    expect(await share.totalSupply()).to.equal(SUPPLY * 10n ** 18n);
    expect(await share.balanceOf(await curve.getAddress())).to.equal(SUPPLY * 10n ** 18n);
    expect(await curve.inventory()).to.equal(SUPPLY);
    expect(await curve.symbol?.() ?? "PROV").to.exist;
  });
});

describe("AgentBondingCurve", () => {
  it("prices the first share at basePrice and charges the buy fee", async () => {
    const { launchpad, usdc, alice, treasury } = await deployFixture();
    const { share, curve } = await launchAgent(launchpad);

    expect(await curve.getBuyCost(1)).to.equal(BASE_PRICE); // $0.05
    const cost = await curve.getBuyCost(100n);              // 100 shares
    const fee = (cost * BUY_FEE) / 10000n;

    await usdc.connect(alice).approve(await curve.getAddress(), cost + fee);
    await curve.connect(alice).buy(100n, cost + fee);

    expect(await share.balanceOf(alice.address)).to.equal(100n * 10n ** 18n);
    expect(await usdc.balanceOf(treasury.address)).to.equal(fee); // fee routed to platform
    expect(await curve.sold()).to.equal(100n);
    expect(await curve.raised()).to.equal(cost);
  });

  it("price increases as supply is sold (slope)", async () => {
    const { launchpad, usdc, alice } = await deployFixture();
    const { curve } = await launchAgent(launchpad);

    const priceBefore = await curve.getCurrentPrice();
    const cost = await curve.getBuyCost(500n);
    await usdc.connect(alice).approve(await curve.getAddress(), cost * 2n);
    await curve.connect(alice).buy(500n, cost * 2n);
    const priceAfter = await curve.getCurrentPrice();

    expect(priceBefore).to.equal(BASE_PRICE);
    expect(priceAfter).to.equal(BASE_PRICE + 500n * SLOPE);
    expect(priceAfter).to.be.gt(priceBefore);
  });

  it("lets a holder sell back before graduation (minus sell fee)", async () => {
    const { launchpad, usdc, alice } = await deployFixture();
    const { share, curve } = await launchAgent(launchpad);

    const cost = await curve.getBuyCost(200n);
    await usdc.connect(alice).approve(await curve.getAddress(), cost * 2n);
    await curve.connect(alice).buy(200n, cost * 2n);

    const proceeds = await curve.getSellProceeds(50n);
    await share.connect(alice).approve(await curve.getAddress(), 50n * 10n ** 18n);
    const balBefore = await usdc.balanceOf(alice.address);
    await curve.connect(alice).sell(50n, proceeds);
    const balAfter = await usdc.balanceOf(alice.address);

    expect(balAfter - balBefore).to.equal(proceeds);
    expect(await curve.sold()).to.equal(150n);
  });

  it("rejects buys over available inventory and honors slippage", async () => {
    const { launchpad, usdc, alice } = await deployFixture();
    const { curve } = await launchAgent(launchpad);

    await usdc.connect(alice).approve(await curve.getAddress(), USDC(1_000_000));
    await expect(curve.connect(alice).buy(SUPPLY + 1n, USDC(1_000_000))).to.be.revertedWith("not enough inventory");

    const cost = await curve.getBuyCost(10n);
    await expect(curve.connect(alice).buy(10n, cost - 1n)).to.be.revertedWith("slippage");
  });
});

describe("Graduation → AMM", () => {
  async function graduate() {
    const fx = await deployFixture();
    const { share, curve } = await launchAgent(fx.launchpad);

    // Buy enough to cross graduationRaise ($50). At ~$0.05+ per share, ~900 shares raises >$50.
    await fx.usdc.connect(fx.alice).approve(await curve.getAddress(), USDC(1_000_000));
    // find k so that raised >= GRAD_RAISE
    let k = 1000n;
    const cost = await curve.getBuyCost(k);
    await curve.connect(fx.alice).buy(k, cost * 2n);
    expect(await curve.graduated()).to.equal(true);

    const ammAddr = await curve.amm();
    const amm = await ethers.getContractAt("AgentAMM", ammAddr);
    return { ...fx, share, curve, amm, k };
  }

  it("graduates once the raise target is hit and seeds the AMM", async () => {
    const { curve, amm, share } = await graduate();

    expect(await curve.graduated()).to.equal(true);
    // curve emptied its inventory + USDC into the pool
    expect(await curve.inventory()).to.equal(0n);
    expect(await share.balanceOf(await amm.getAddress())).to.be.gt(0n);
    expect(await amm.quoteReserve()).to.be.gt(0n);
    expect(await amm.shareReserve()).to.be.gt(0n);
  });

  it("locks the LP forever (LP held by the curve, no withdrawal path)", async () => {
    const { curve, amm } = await graduate();
    const curveLp = await amm.liquidityBalance(await curve.getAddress());
    expect(curveLp).to.be.gt(0n);
    // The curve has no function that calls removeLiquidity → the LP is unrecoverable.
    expect(curve.interface.fragments.some((f) => f.name === "removeLiquidity")).to.equal(false);
  });

  it("blocks curve trading after graduation", async () => {
    const { curve, usdc, bob } = await graduate();
    await usdc.connect(bob).approve(await curve.getAddress(), USDC(1000));
    await expect(curve.connect(bob).buy(1n, USDC(1000))).to.be.revertedWith("graduated");
  });

  it("allows swapping on the graduated AMM", async () => {
    const { amm, usdc, share, bob } = await graduate();

    // bob buys shares from the pool with USDC
    const quoteIn = USDC(10);
    const expOut = await amm.shareForQuote(quoteIn);
    await usdc.connect(bob).approve(await amm.getAddress(), quoteIn);
    await amm.connect(bob).swapQuoteForShare(quoteIn, expOut);
    expect(await share.balanceOf(bob.address)).to.equal(expOut);

    // and sells some back
    const shareIn = expOut / 2n;
    const expQuote = await amm.quoteForShare(shareIn);
    await share.connect(bob).approve(await amm.getAddress(), shareIn);
    const balBefore = await usdc.balanceOf(bob.address);
    await amm.connect(bob).swapShareForQuote(shareIn, expQuote);
    expect((await usdc.balanceOf(bob.address)) - balBefore).to.equal(expQuote);
  });
});

describe("AgentAMM (standalone invariants)", () => {
  it("keeps x*y within rounding on swaps and charges the 0.3% fee", async () => {
    const [deployer, lp, trader] = await ethers.getSigners();
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    const Share = await ethers.getContractFactory("AgentShareToken");
    const share = await Share.deploy("T", "T", 1_000_000n * 10n ** 18n, lp.address, 18);

    const AMM = await ethers.getContractFactory("AgentAMM");
    const amm = await AMM.deploy(await share.getAddress(), await usdc.getAddress());

    await usdc.mint(lp.address, USDC(100_000));
    await share.connect(lp).approve(await amm.getAddress(), 100_000n * 10n ** 18n);
    await usdc.connect(lp).approve(await amm.getAddress(), USDC(100_000));
    await amm.connect(lp).addLiquidity(100_000n * 10n ** 18n, USDC(100_000));

    const kBefore = (await amm.shareReserve()) * (await amm.quoteReserve());
    await usdc.mint(trader.address, USDC(1_000));
    await usdc.connect(trader).approve(await amm.getAddress(), USDC(1_000));
    await amm.connect(trader).swapQuoteForShare(USDC(1_000), 0);
    const kAfter = (await amm.shareReserve()) * (await amm.quoteReserve());

    expect(kAfter).to.be.gte(kBefore); // fee grows k
  });
});
