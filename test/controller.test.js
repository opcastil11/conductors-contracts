const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * The one-way A→B crossing (docs/TOKENOMICS-V2.md §3–§4).
 *
 * What these tests are actually pinning down, beyond "the happy path works":
 *  - the reserve released as capex is EXACTLY the claim retired, so the curve stays solvent for
 *    everyone who did not convert — the whole argument of §4.1;
 *  - conversion is rationed at one fixed ratio rather than 1:1-until-empty, which is what makes
 *    "each retained point lowers A's floor proportionally" true (§6.2);
 *  - the grace period and the KYC gate are hard closes, not UI conventions;
 *  - post-graduation the AMM shrinks on both legs, leaving its price untouched;
 *  - the controller has no discretionary path to funds, and no second controller can be bound.
 */

// Economics, priced in DOBX (18dp): $0.05 → $0.25 over 200k shares.
const SUPPLY = 1_000_000n;
const BASE_PRICE = 5n * 10n ** 16n;   // 0.05 DOBX per whole share
const SLOPE = 10n ** 12n;             // +1e-6 DOBX per share sold
const GRAD_RAISE_HIGH = 3n * 10n ** 22n; // ~30k DOBX — not reached in the pre-graduation tests
const GRAD_RAISE_LOW = 10n ** 21n;       // 1k DOBX — reached after ~17.5k shares
const BUY_FEE = 100n;  // 1%
const SELL_FEE = 100n; // 1%
const WAD = 10n ** 18n;
const DL = ethers.MaxUint256;

const B_TOTAL = SUPPLY * WAD;  // same cap as A
const RETAINED_BPS = 3000n;    // creator keeps 30% ⇒ every A converts at 0.7 B

/** The curve's exact integral over `k` shares starting at position `from`. */
const integral = (from, k) => k * BASE_PRICE + (SLOPE * (2n * from + k - 1n) * k) / 2n;

async function deploy({ gradRaise = GRAD_RAISE_HIGH, retainedBps = RETAINED_BPS, grace = 0n, cliff = 0n, vest = 0n } = {}) {
  const [owner, platformTreasury, creator, capexSink, alice, bob] = await ethers.getSigners();

  const dobx = await (await ethers.getContractFactory("DOBX")).deploy(owner.address);
  const bToken = await (await ethers.getContractFactory("MockParticipation")).deploy();
  const kyc = await (await ethers.getContractFactory("KycRegistry")).deploy(owner.address, owner.address);
  const ctrlFactory = await (await ethers.getContractFactory("AgentControllerFactory")).deploy();

  const launchpad = await (await ethers.getContractFactory("AgentLaunchpad"))
    .deploy(owner.address, await dobx.getAddress(), platformTreasury.address);
  await (await launchpad.setKycRegistry(await kyc.getAddress())).wait();
  await (await launchpad.setControllerFactory(await ctrlFactory.getAddress())).wait();

  // Everyone trades in DOBX.
  for (const u of [alice, bob]) await (await dobx.transfer(u.address, 10n ** 24n)).wait();

  // `launch()` is gated by design, so the creator has to be authorized first.
  await (await launchpad.setAuthorizedLauncher(creator.address, true)).wait();
  await (await launchpad.connect(creator).launch({
    name: "Providencia EV Hub", symbol: "PROV", supply: SUPPLY, basePrice: BASE_PRICE,
    slope: SLOPE, buyFeeBps: BUY_FEE, sellFeeBps: SELL_FEE, graduationRaise: gradRaise,
    creator: creator.address, feeRecipient: ethers.ZeroAddress,
  })).wait();
  const l = await launchpad.getLaunch(0);
  const share = await ethers.getContractAt("AgentShareToken", l.token);
  const curve = await ethers.getContractAt("AgentBondingCurve", l.curve);

  return {
    owner, platformTreasury, creator, capexSink, alice, bob,
    dobx, bToken, kyc, launchpad, share, curve,
    retainedBps, grace, cliff, vest,
  };
}

/** Deploy the controller, seed it with B, and (unless told not to) activate it. */
async function attachController(f, { activate = true, seedB = B_TOTAL } = {}) {
  await (await f.launchpad.deployController(0, {
    participationToken: await f.bToken.getAddress(),
    capexSink: f.capexSink.address,
    retainedBps: f.retainedBps,
    graceSeconds: f.grace,
    cliffSeconds: f.cliff,
    vestSeconds: f.vest,
  })).wait();
  const addr = (await f.launchpad.getLaunch(0)).controller;
  const controller = await ethers.getContractAt("AgentController", addr);
  if (seedB > 0n) await (await f.bToken.mint(addr, seedB)).wait();
  if (activate) await (await f.launchpad.activateController(0, seedB)).wait();
  return controller;
}

async function buy(f, who, shares) {
  const cost = await f.curve.getBuyCost(shares);
  const total = cost + (cost * BUY_FEE) / 10000n;
  await (await f.dobx.connect(who).approve(await f.curve.getAddress(), total)).wait();
  await (await f.curve.connect(who).buy(shares, total, DL)).wait();
}

async function convert(f, controller, who, shares, minQuote = 0n) {
  await (await f.share.connect(who).approve(await controller.getAddress(), shares * WAD)).wait();
  return controller.connect(who).convert(shares, minQuote);
}

// ─────────────────────────────────────────────────────────────────────────────

describe("DOBX — the quote token of every curve", () => {
  it("mints a fixed supply to the treasury and exposes no mint", async () => {
    const [owner] = await ethers.getSigners();
    const dobx = await (await ethers.getContractFactory("DOBX")).deploy(owner.address);
    expect(await dobx.totalSupply()).to.equal(10n ** 9n * WAD);
    expect(await dobx.balanceOf(owner.address)).to.equal(10n ** 9n * WAD);
    expect(dobx.interface.fragments.some((fr) => fr.name === "mint")).to.equal(false);
    expect(await dobx.symbol()).to.equal("DAM");
    expect(await dobx.name()).to.equal("DAM");
  });

  it("only ever shrinks: burn reduces total supply", async () => {
    const [owner] = await ethers.getSigners();
    const dobx = await (await ethers.getContractFactory("DOBX")).deploy(owner.address);
    await (await dobx.burn(1000n * WAD)).wait();
    expect(await dobx.totalSupply()).to.equal(10n ** 9n * WAD - 1000n * WAD);
  });

  it("prices the curve — a launched agent quotes in DOBX, not USDC", async () => {
    const f = await deploy();
    expect(await f.curve.quoteToken()).to.equal(await f.dobx.getAddress());
  });
});

describe("AgentController — binding", () => {
  it("deploys once per agent and binds itself to the curve", async () => {
    const f = await deploy();
    const controller = await attachController(f, { activate: false });
    expect(await f.curve.controller()).to.equal(await controller.getAddress());
    expect((await f.launchpad.getLaunch(0)).controller).to.equal(await controller.getAddress());
  });

  it("refuses a second controller — the crossing cannot be re-pointed later", async () => {
    const f = await deploy();
    await attachController(f, { activate: false });
    await expect(f.launchpad.deployController(0, {
      participationToken: await f.bToken.getAddress(),
      capexSink: f.capexSink.address,
      retainedBps: 0, graceSeconds: 0, cliffSeconds: 0, vestSeconds: 0,
    })).to.be.revertedWith("already deployed");
    // …and the curve itself would refuse even if the launchpad were tricked into trying.
    await expect(f.curve.bindController(f.alice.address)).to.be.revertedWith("not launchpad");
  });

  it("lets nobody but the bound controller burn A for conversion", async () => {
    const f = await deploy();
    await attachController(f);
    await expect(f.curve.connect(f.alice).redeemForConversion(1n, 0n)).to.be.revertedWith("not controller");
  });

  it("activates once, snapshotting the cap table split", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    expect(await controller.convertibleB()).to.equal((B_TOTAL * 7000n) / 10000n);
    expect(await controller.retainedB()).to.equal((B_TOTAL * 3000n) / 10000n);
    expect(await controller.aSupplyAtActivation()).to.equal(SUPPLY * WAD);
    await expect(f.launchpad.activateController(0, B_TOTAL)).to.be.revertedWith("activated");
  });
});

describe("AgentController — the gates", () => {
  it("closes conversion for the whole grace period", async () => {
    const f = await deploy({ grace: 365n * 24n * 3600n });
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await buy(f, f.alice, 1000n);

    await expect(convert(f, controller, f.alice, 100n)).to.be.revertedWith("grace period");

    await time.increase(365n * 24n * 3600n + 1n);
    await expect(convert(f, controller, f.alice, 100n)).to.not.be.reverted;
  });

  it("requires KYC at the crossing — and nowhere else", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await buy(f, f.alice, 1000n);

    // Trading A is permissionless: alice can buy and sell with no approval anywhere.
    expect(await f.kyc.isApproved(f.alice.address)).to.equal(false);
    await expect(convert(f, controller, f.alice, 100n)).to.be.revertedWith("kyc required");

    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await expect(convert(f, controller, f.alice, 100n)).to.not.be.reverted;
  });
});

describe("AgentController — conversion before graduation", () => {
  it("burns the A, pays the exact reserve it retired to capex, and issues B at the fixed ratio", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await buy(f, f.alice, 10_000n);

    const raisedBefore = await f.curve.raised();
    const expectedRelease = integral(9_000n, 1_000n); // top-of-curve slice for the 1k crossing

    await (await convert(f, controller, f.alice, 1_000n)).wait();

    // A is gone from the supply, not parked somewhere.
    expect(await f.share.totalSupply()).to.equal(SUPPLY * WAD - 1_000n * WAD);
    expect(await f.curve.burned()).to.equal(1_000n);
    expect(await f.curve.sold()).to.equal(9_000n);

    // The released reserve went straight through the controller to the sink.
    expect(await f.dobx.balanceOf(f.capexSink.address)).to.equal(expectedRelease);
    expect(await f.dobx.balanceOf(await controller.getAddress())).to.equal(0n);
    expect(await f.curve.raised()).to.equal(raisedBefore - expectedRelease);
    expect(await f.curve.capexReleased()).to.equal(expectedRelease);

    // 30% retained ⇒ 1 A buys 0.7 B, for everyone, not just the first movers.
    expect(await f.bToken.balanceOf(f.alice.address)).to.equal(700n * WAD);
  });

  it("leaves the curve solvent for everyone who did not convert", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await buy(f, f.alice, 10_000n);
    await (await convert(f, controller, f.alice, 1_000n)).wait();

    // The 9k A still outstanding must all be redeemable against what is left of the reserve.
    const proceeds = await f.curve.getSellProceeds(9_000n);
    expect(proceeds).to.be.lte(await f.curve.raised());
    await (await f.share.connect(f.alice).approve(await f.curve.getAddress(), 9_000n * WAD)).wait();
    await expect(f.curve.connect(f.alice).sell(9_000n, 0n, DL)).to.not.be.reverted;
    expect(await f.curve.sold()).to.equal(0n);
  });

  it("does not hand burned shares back to the curve's inventory", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await buy(f, f.alice, 10_000n);
    const invBefore = await f.curve.inventory();
    await (await convert(f, controller, f.alice, 1_000n)).wait();
    // sold fell by 1k but burned rose by 1k — inventory is unchanged, the shares are simply gone.
    expect(await f.curve.inventory()).to.equal(invBefore);
  });

  it("rations the convertible B — the pool cannot be over-drawn", async () => {
    // Retain the 50% cap: half of B is convertible, so the ratio is 0.5 B per A.
    const f = await deploy({ retainedBps: 5000n });
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await buy(f, f.alice, 10_000n);
    expect(await controller.quoteConversion(1_000n)).to.equal(500n * WAD);
    await (await convert(f, controller, f.alice, 1_000n)).wait();
    expect(await f.bToken.balanceOf(f.alice.address)).to.equal(500n * WAD);
  });

  it("refuses a controller that retains everything (A would have no floor at all)", async () => {
    const f = await deploy({ retainedBps: 10000n });
    await expect(attachController(f, { activate: false })).to.be.reverted;
  });

  it("honors minQuoteToCapex", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await buy(f, f.alice, 10_000n);
    const expected = integral(9_000n, 1_000n);
    await (await f.share.connect(f.alice).approve(await controller.getAddress(), 1_000n * WAD)).wait();
    await expect(controller.connect(f.alice).convert(1_000n, expected + 1n)).to.be.revertedWith("slippage");
  });
});

describe("AgentController — conversion after graduation", () => {
  async function graduated() {
    const f = await deploy({ gradRaise: GRAD_RAISE_LOW });
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await buy(f, f.alice, 20_000n);
    expect(await f.curve.graduated()).to.equal(true);
    const amm = await ethers.getContractAt("AgentAMM", await f.curve.amm());
    return { ...f, controller, amm };
  }

  it("withdraws the matching slice of the locked LP and sends it to capex", async () => {
    const f = await graduated();
    const quoteBefore = await f.amm.quoteReserve();
    expect(quoteBefore).to.be.gt(0n);

    await (await convert(f, f.controller, f.alice, 1_000n)).wait();

    const sinkBalance = await f.dobx.balanceOf(f.capexSink.address);
    expect(sinkBalance).to.be.gt(0n);
    expect(await f.amm.quoteReserve()).to.equal(quoteBefore - sinkBalance);
    expect(await f.dobx.balanceOf(await f.controller.getAddress())).to.equal(0n);
  });

  it("shrinks both legs, so the AMM price is unchanged by a conversion", async () => {
    const f = await graduated();
    const pxBefore = (await f.amm.quoteReserve()) * WAD / (await f.amm.shareReserve());

    await (await convert(f, f.controller, f.alice, 1_000n)).wait();

    const pxAfter = (await f.amm.quoteReserve()) * WAD / (await f.amm.shareReserve());
    const drift = pxAfter > pxBefore ? pxAfter - pxBefore : pxBefore - pxAfter;
    expect(drift * 1_000_000n / pxBefore).to.be.lt(100n); // <0.01% — integer-division dust only
  });

  it("burns the AMM-side A along with the converted A", async () => {
    const f = await graduated();
    const supplyBefore = await f.share.totalSupply();
    await (await convert(f, f.controller, f.alice, 1_000n)).wait();
    // At least the 1k crossed, plus the share leg that came back with the LP withdrawal.
    expect(supplyBefore - (await f.share.totalSupply())).to.be.gt(1_000n * WAD);
  });
});

describe("AgentController — the creator's retained B", () => {
  const YEAR = 365n * 24n * 3600n;

  it("releases nothing before the cliff", async () => {
    const f = await deploy({ cliff: YEAR, vest: 2n * YEAR });
    const controller = await attachController(f);
    expect(await controller.vestedRetained()).to.equal(0n);
    await expect(controller.releaseRetained()).to.be.revertedWith("nothing vested");
  });

  it("vests linearly after the cliff and pays out pull-based", async () => {
    const f = await deploy({ cliff: YEAR, vest: 2n * YEAR });
    const controller = await attachController(f);
    const retained = await controller.retainedB();

    await time.increase(YEAR + YEAR); // cliff + half the vesting window
    const vested = await controller.vestedRetained();
    expect(vested).to.be.closeTo(retained / 2n, retained / 1000n);

    await (await controller.releaseRetained()).wait();
    expect(await f.bToken.balanceOf(f.creator.address)).to.be.closeTo(retained / 2n, retained / 500n);

    await time.increase(2n * YEAR);
    await (await controller.releaseRetained()).wait();
    expect(await f.bToken.balanceOf(f.creator.address)).to.equal(retained);
  });

  it("never lets the creator reach the convertible side", async () => {
    const f = await deploy({ cliff: 0n, vest: 0n });
    const controller = await attachController(f);
    await (await controller.releaseRetained()).wait();
    expect(await f.bToken.balanceOf(f.creator.address)).to.equal((B_TOTAL * RETAINED_BPS) / 10000n);
    await expect(controller.releaseRetained()).to.be.revertedWith("nothing vested");
    // Everything else is still there for converters.
    expect(await f.bToken.balanceOf(await controller.getAddress())).to.equal(await controller.convertibleB());
  });

  it("exposes no sweep: the ABI has no owner and no discretionary transfer", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    const names = controller.interface.fragments.filter((fr) => fr.type === "function").map((fr) => fr.name);
    for (const forbidden of ["owner", "transferOwnership", "sweep", "rescue", "withdraw", "setCapexSink", "upgradeTo"]) {
      expect(names, `AgentController must not expose ${forbidden}`).to.not.include(forbidden);
    }
  });
});

describe("Hardening — activation, launch params and owner bounds", () => {
  it("only the launchpad (its owner) can activate, and dust sent first cannot freeze the split", async () => {
    const f = await deploy();
    const controller = await attachController(f, { activate: false, seedB: 0n });
    // A stranger front-runs with 1 wei of B and tries to open the crossing on it.
    await (await f.bToken.mint(await controller.getAddress(), 1n)).wait();
    await expect(controller.connect(f.alice).activate(1n)).to.be.revertedWith("not activator");
    await expect(f.launchpad.connect(f.alice).activateController(0, 1n)).to.be.reverted;
    // The real B arrives; the owner activates on the stated amount, not on whatever is there.
    await (await f.bToken.mint(await controller.getAddress(), B_TOTAL)).wait();
    await (await f.launchpad.activateController(0, B_TOTAL)).wait();
    expect(await controller.convertibleB()).to.equal((B_TOTAL * 7000n) / 10000n);
  });

  it("refuses to activate on B that has not arrived", async () => {
    const f = await deploy();
    await attachController(f, { activate: false, seedB: B_TOTAL / 2n });
    await expect(f.launchpad.activateController(0, B_TOTAL)).to.be.revertedWith("B not here");
  });

  it("records the explicit creator, not the caller, and pays retained B to it", async () => {
    const f = await deploy();
    const l = await f.launchpad.getLaunch(0);
    expect(l.creator).to.equal(f.creator.address);
    const [, , , , , , stranger] = await ethers.getSigners();
    await (await f.launchpad.launch({
      name: "X", symbol: "X", supply: SUPPLY, basePrice: BASE_PRICE, slope: SLOPE,
      buyFeeBps: BUY_FEE, sellFeeBps: SELL_FEE, graduationRaise: GRAD_RAISE_HIGH,
      creator: stranger.address, feeRecipient: f.bob.address,
    })).wait();
    const l1 = await f.launchpad.getLaunch(1);
    expect(l1.creator).to.equal(stranger.address);
    const c1 = await ethers.getContractAt("AgentBondingCurve", l1.curve);
    expect(await c1.feeRecipient()).to.equal(f.bob.address);
    await expect(f.launchpad.launch({
      name: "Y", symbol: "Y", supply: SUPPLY, basePrice: BASE_PRICE, slope: SLOPE,
      buyFeeBps: BUY_FEE, sellFeeBps: SELL_FEE, graduationRaise: GRAD_RAISE_HIGH,
      creator: ethers.ZeroAddress, feeRecipient: ethers.ZeroAddress,
    })).to.be.revertedWith("zero creator");
  });

  it("bounds what the owner can stamp into a controller", async () => {
    const f = await deploy();
    const base = {
      participationToken: await f.bToken.getAddress(), capexSink: f.capexSink.address,
      retainedBps: 3000, graceSeconds: 0, cliffSeconds: 0, vestSeconds: 0,
    };
    await expect(f.launchpad.deployController(0, { ...base, retainedBps: 5001 })).to.be.revertedWith("retained too high");
    await expect(f.launchpad.deployController(0, { ...base, graceSeconds: 366n * 86400n })).to.be.revertedWith("schedule too long");
    await expect(f.launchpad.deployController(0, { ...base, vestSeconds: 5n * 365n * 86400n })).to.be.revertedWith("schedule too long");
    await expect(f.launchpad.deployController(0, { ...base, participationToken: await f.share.getAddress() })).to.be.revertedWith("bad B");
    await expect(f.launchpad.deployController(0, { ...base, participationToken: await f.dobx.getAddress() })).to.be.revertedWith("bad B");
    await expect(f.launchpad.deployController(0, { ...base, capexSink: await f.curve.getAddress() })).to.be.revertedWith("bad sink");
  });

  it("puts a replacement controller factory behind a 2-day timelock", async () => {
    const f = await deploy();
    const original = await f.launchpad.controllerFactory();
    const other = await (await ethers.getContractFactory("AgentControllerFactory")).deploy();
    await (await f.launchpad.setControllerFactory(await other.getAddress())).wait();
    expect(await f.launchpad.controllerFactory()).to.equal(original);
    await expect(f.launchpad.acceptControllerFactory()).to.be.revertedWith("timelocked");
    await time.increase(2n * 86400n);
    await (await f.launchpad.acceptControllerFactory()).wait();
    expect(await f.launchpad.controllerFactory()).to.equal(await other.getAddress());
  });

  it("burns unsold A at graduation, so nobody holds unbacked A that could cross to B", async () => {
    const f = await deploy({ gradRaise: GRAD_RAISE_LOW });
    const supplyBefore = await f.share.totalSupply();
    let shares = 0n;
    while (!(await f.curve.graduated())) { await buy(f, f.alice, 5_000n); shares += 5_000n; }
    const amm = await ethers.getContractAt("AgentAMM", await f.curve.amm());
    expect(await f.share.balanceOf(f.platformTreasury.address)).to.equal(0n);
    // What is left is exactly what buyers hold plus the AMM's seed — every A has quote behind it.
    expect(await f.share.totalSupply()).to.equal(shares * WAD + (await amm.shareReserve()));
    expect(await f.share.totalSupply()).to.be.lt(supplyBefore);
  });

  it("ignores A donated to the AMM when sizing a post-graduation release", async () => {
    const f = await deploy({ gradRaise: GRAD_RAISE_LOW });
    const controller = await attachController(f, { activate: false });
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    while (!(await f.curve.graduated())) await buy(f, f.alice, 5_000n);
    await (await f.launchpad.activateController(0, B_TOTAL)).wait();
    const amm = await f.curve.amm();
    const snap = await ethers.provider.send("evm_snapshot", []);
    await (await convert(f, controller, f.alice, 100n)).wait();
    const clean = await controller.capexFunded();
    await ethers.provider.send("evm_revert", [snap]);
    await (await f.share.connect(f.alice).transfer(amm, 1_000n * WAD)).wait(); // donation
    await (await convert(f, controller, f.alice, 100n)).wait();
    expect(await controller.capexFunded()).to.equal(clean);
  });
});

describe("Hardening — precision, reachability and fixed roles", () => {
  it("refuses to activate on B too coarse to split per whole A", async () => {
    const f = await deploy();
    await attachController(f, { activate: false, seedB: 1000n });
    await expect(f.launchpad.activateController(0, 1000n)).to.be.revertedWith("B too coarse");
  });

  it("validates graduation against the supply−1 shares that can actually be sold", async () => {
    const f = await deploy();
    const base = {
      name: "X", symbol: "X", supply: SUPPLY, basePrice: BASE_PRICE, slope: SLOPE,
      buyFeeBps: BUY_FEE, sellFeeBps: SELL_FEE, creator: f.creator.address, feeRecipient: ethers.ZeroAddress,
    };
    await expect(f.launchpad.launch({ ...base, graduationRaise: integral(0n, SUPPLY) })).to.be.revertedWith("grad unreachable");
    await (await f.launchpad.launch({ ...base, graduationRaise: integral(0n, SUPPLY - 1n) })).wait();
  });

  it("a pre-graduation conversion may not leave the goal out of reach", async () => {
    const f = await deploy({ gradRaise: integral(0n, SUPPLY - 1n) });
    const controller = await attachController(f);
    await buy(f, f.alice, 10n);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await expect(convert(f, controller, f.alice, 1n)).to.be.revertedWith("grad unreachable");
  });

  it("the quote token is fixed for the launchpad's life", async () => {
    const f = await deploy();
    expect(f.launchpad.interface.fragments.some((fr) => fr.name === "setQuoteToken")).to.equal(false);
  });
});
