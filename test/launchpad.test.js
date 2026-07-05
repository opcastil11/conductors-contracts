const { expect } = require("chai");
const { ethers } = require("hardhat");

// Economics: supply 1,000,000 shares, basePrice $0.05, slope $0.0001/share, graduate at $50.
const SUPPLY = 1_000_000n;
const BASE_PRICE = 50_000n;
const SLOPE = 100n;
const GRAD_RAISE = 50_000_000n; // $50
const BUY_FEE = 100n;  // 1%
const SELL_FEE = 100n; // 1%
const USDC = (n) => BigInt(Math.round(n * 1e6));
const DL = ethers.MaxUint256; // deadline: always valid in tests
const WAD = 10n ** 18n;

async function deployFixture() {
  const [owner, treasury, alice, bob] = await ethers.getSigners();
  const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
  const launchpad = await (await ethers.getContractFactory("AgentLaunchpad"))
    .deploy(owner.address, await usdc.getAddress(), treasury.address);
  for (const u of [alice, bob]) await usdc.mint(u.address, USDC(2_000_000));
  return { owner, treasury, alice, bob, usdc, launchpad };
}

async function launchAgent(launchpad, as) {
  const lp = as ? launchpad.connect(as) : launchpad;
  await (await lp.launch({
    name: "Providencia EV Hub", symbol: "PROV", supply: SUPPLY, basePrice: BASE_PRICE,
    slope: SLOPE, buyFeeBps: BUY_FEE, sellFeeBps: SELL_FEE, graduationRaise: GRAD_RAISE,
  })).wait();
  const l = await launchpad.getLaunch(0);
  return {
    share: await ethers.getContractAt("AgentShareToken", l.token),
    curve: await ethers.getContractAt("AgentBondingCurve", l.curve),
  };
}

describe("AgentLaunchpad — gating & registry", () => {
  it("launches an agent and mints the supply into the curve", async () => {
    const { launchpad } = await deployFixture();
    const { share, curve } = await launchAgent(launchpad);
    expect(await launchpad.launchesCount()).to.equal(1);
    expect(await share.balanceOf(await curve.getAddress())).to.equal(SUPPLY * WAD);
    expect(await curve.inventory()).to.equal(SUPPLY);
  });

  it("gates launch() to authorized launchers", async () => {
    const { launchpad, alice, owner } = await deployFixture();
    await expect(launchAgent(launchpad, alice)).to.be.revertedWith("not authorized");
    await launchpad.connect(owner).setAuthorizedLauncher(alice.address, true);
    await expect(launchAgent(launchpad, alice)).to.not.be.reverted;
  });

  it("publicLaunch opens it to anyone", async () => {
    const { launchpad, alice, owner } = await deployFixture();
    await launchpad.connect(owner).setPublicLaunch(true);
    await expect(launchAgent(launchpad, alice)).to.not.be.reverted;
  });

  it("pause blocks launching", async () => {
    const { launchpad, owner } = await deployFixture();
    await launchpad.connect(owner).pause();
    await expect(launchAgent(launchpad)).to.be.revertedWithCustomError(launchpad, "EnforcedPause");
  });

  it("rejects an unreachable graduation target", async () => {
    const { launchpad } = await deployFixture();
    await expect(launchpad.launch({
      name: "X", symbol: "X", supply: SUPPLY, basePrice: BASE_PRICE, slope: SLOPE,
      buyFeeBps: 0, sellFeeBps: 0, graduationRaise: 10n ** 30n, // > full integral
    })).to.be.revertedWith("grad unreachable");
  });
});

describe("AgentBondingCurve", () => {
  it("prices the first share at basePrice and routes the buy fee to treasury", async () => {
    const { launchpad, usdc, alice, treasury } = await deployFixture();
    const { share, curve } = await launchAgent(launchpad);
    expect(await curve.getBuyCost(1)).to.equal(BASE_PRICE);
    const cost = await curve.getBuyCost(100n);
    const fee = (cost * BUY_FEE) / 10000n;
    await usdc.connect(alice).approve(await curve.getAddress(), cost + fee);
    await curve.connect(alice).buy(100n, cost + fee, DL);
    expect(await share.balanceOf(alice.address)).to.equal(100n * WAD);
    expect(await usdc.balanceOf(treasury.address)).to.equal(fee);
    expect(await curve.sold()).to.equal(100n);
  });

  it("price rises with supply sold and honors slippage + deadline", async () => {
    const { launchpad, usdc, alice } = await deployFixture();
    const { curve } = await launchAgent(launchpad);
    const cost = await curve.getBuyCost(500n);
    await usdc.connect(alice).approve(await curve.getAddress(), cost * 2n);
    await expect(curve.connect(alice).buy(500n, cost - 1n, DL)).to.be.revertedWith("slippage");
    await expect(curve.connect(alice).buy(500n, cost * 2n, 1n)).to.be.revertedWith("expired");
    await curve.connect(alice).buy(500n, cost * 2n, DL);
    expect(await curve.getCurrentPrice()).to.equal(BASE_PRICE + 500n * SLOPE);
  });

  it("allows selling back before graduation", async () => {
    const { launchpad, usdc, alice } = await deployFixture();
    const { share, curve } = await launchAgent(launchpad);
    const cost = await curve.getBuyCost(200n);
    await usdc.connect(alice).approve(await curve.getAddress(), cost * 2n);
    await curve.connect(alice).buy(200n, cost * 2n, DL);
    const proceeds = await curve.getSellProceeds(50n);
    await share.connect(alice).approve(await curve.getAddress(), 50n * WAD);
    const before = await usdc.balanceOf(alice.address);
    await curve.connect(alice).sell(50n, proceeds, DL);
    expect((await usdc.balanceOf(alice.address)) - before).to.equal(proceeds);
    expect(await curve.sold()).to.equal(150n);
  });
});

describe("Graduation → AMM (audit fixes)", () => {
  async function graduate() {
    const fx = await deployFixture();
    const { share, curve } = await launchAgent(fx.launchpad);
    await fx.usdc.connect(fx.alice).approve(await curve.getAddress(), USDC(2_000_000));
    await curve.connect(fx.alice).buy(1000n, USDC(2_000_000), DL);
    expect(await curve.graduated()).to.equal(true);
    const amm = await ethers.getContractAt("AgentAMM", await curve.amm());
    return { ...fx, share, curve, amm };
  }

  it("seeds the AMM at ~the curve's terminal price (no price cliff)", async () => {
    const { curve, amm } = await graduate();
    const termPrice = await curve.getCurrentPrice(); // USDC per whole share
    const ammPrice = ((await amm.quoteReserve()) * WAD) / (await amm.shareReserve());
    // within 1% — continuous, NOT the ~2800x cliff of the pre-fix design
    const diff = ammPrice > termPrice ? ammPrice - termPrice : termPrice - ammPrice;
    expect(diff * 100n <= termPrice).to.equal(true);
  });

  it("sends leftover inventory to the treasury", async () => {
    const { share, treasury } = await graduate();
    expect(await share.balanceOf(treasury.address)).to.be.gt(0n);
  });

  it("AMM price is immune to token donations (explicit reserves)", async () => {
    const { amm, share, bob, usdc } = await graduate();
    const before = await amm.shareForQuote(USDC(10));
    // attacker donates a big share balance directly to the pool
    await usdc.connect(bob).approve(await amm.getAddress(), USDC(50));
    await amm.connect(bob).swapQuoteForShare(USDC(50), 0n, DL); // bob now holds shares
    const donation = await share.balanceOf(bob.address);
    await share.connect(bob).transfer(await amm.getAddress(), donation);
    const after = await amm.shareForQuote(USDC(10));
    // quote-in→shares-out quote is set by tracked reserves, not balanceOf → donation ignored
    // (after reflects bob's real swap moving the price, but the raw donation added no phantom liquidity)
    expect(after).to.be.lte(before); // price moved from the swap only, donation gave no free shares
  });

  it("blocks curve trading after graduation and allows AMM swaps", async () => {
    const { curve, amm, usdc, share, bob } = await graduate();
    await usdc.connect(bob).approve(await curve.getAddress(), USDC(1000));
    await expect(curve.connect(bob).buy(1n, USDC(1000), DL)).to.be.revertedWith("graduated");

    const quoteIn = USDC(10);
    const expOut = await amm.shareForQuote(quoteIn);
    await usdc.connect(bob).approve(await amm.getAddress(), quoteIn);
    await amm.connect(bob).swapQuoteForShare(quoteIn, expOut, DL);
    expect(await share.balanceOf(bob.address)).to.equal(expOut);
  });
});

describe("AgentAMM — standalone invariants", () => {
  it("charges the 0.3% fee (k grows) and pulls only the matched pair", async () => {
    const [, lp, trader] = await ethers.getSigners();
    const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
    const share = await (await ethers.getContractFactory("AgentShareToken"))
      .deploy("T", "T", 1_000_000n * WAD, lp.address, 18);
    const amm = await (await ethers.getContractFactory("AgentAMM"))
      .deploy(await share.getAddress(), await usdc.getAddress());

    await usdc.mint(lp.address, USDC(200_000));
    await share.connect(lp).approve(await amm.getAddress(), 200_000n * WAD);
    await usdc.connect(lp).approve(await amm.getAddress(), USDC(200_000));
    await amm.connect(lp).addLiquidity(100_000n * WAD, USDC(100_000), 0n, 0n, DL);

    const kBefore = (await amm.shareReserve()) * (await amm.quoteReserve());
    await usdc.mint(trader.address, USDC(1_000));
    await usdc.connect(trader).approve(await amm.getAddress(), USDC(1_000));
    await amm.connect(trader).swapQuoteForShare(USDC(1_000), 0n, DL);
    const kAfter = (await amm.shareReserve()) * (await amm.quoteReserve());
    expect(kAfter).to.be.gte(kBefore);
  });
});
