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

const DAY = 86400n;
const MIN_GRACE = 2n * DAY;
const COLLECT = 12n * 3600n;
const PRICING = 24n * 3600n;

async function deploy({ gradRaise = GRAD_RAISE_LOW, retainedBps = RETAINED_BPS, grace = MIN_GRACE, cliff = 0n, vest = 0n } = {}) {
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

/** Buy exactly up to the graduation point (the crossing only opens after it). */
async function graduate(f, who = f.alice) {
  if (await f.curve.graduated()) return;
  const sold = await f.curve.sold();
  const goal = await f.curve.graduationRaise();
  let lo = sold + 1n, hi = SUPPLY - 1n;
  while (lo < hi) { const m = (lo + hi) / 2n; if (integral(0n, m) >= goal) hi = m; else lo = m + 1n; }
  await buy(f, who, lo - sold);
}

/**
 * Deploy the controller, seed it with B, and (unless told not to) graduate, activate it and wait
 * out the grace period. B exists before the controller does (the launchpad checks its supply).
 */
async function attachController(f, { activate = true, seedB = B_TOTAL, bSupply = B_TOTAL, waitGrace = true } = {}) {
  if ((await f.bToken.totalSupply()) === 0n) await (await f.bToken.mint(f.owner.address, bSupply)).wait();
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
  if (seedB > 0n) await (await f.bToken.transfer(addr, seedB)).wait();
  if (activate) {
    await graduate(f);
    await (await f.launchpad.activateController(0, seedB)).wait();
    await time.increase((waitGrace ? f.grace : 0n) + 3601n);
  }
  return controller;
}

async function buy(f, who, shares) {
  const cost = await f.curve.getBuyCost(shares);
  const total = cost + (cost * BUY_FEE) / 10000n;
  await (await f.dobx.connect(who).approve(await f.curve.getAddress(), total)).wait();
  await (await f.curve.connect(who).buy(shares, total, DL)).wait();
}

/** Request into the collecting batch and return its id. */
async function request(f, controller, who, shares) {
  await (await f.share.connect(who).approve(await controller.getAddress(), shares * WAD)).wait();
  const id = await controller.connect(who).requestConversion.staticCall(shares);
  await (await controller.connect(who).requestConversion(shares)).wait();
  return id;
}

/** The whole crossing for one requester: request → batch closes → pricing window → claim. */
async function convert(f, controller, who, shares) {
  const id = await request(f, controller, who, shares);
  await time.increase(COLLECT);
  await (await controller.poke()).wait();
  await time.increase(PRICING);
  return controller.connect(who).claim(id);
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
    await expect(f.curve.connect(f.alice).redeemForConversion(1n, 0n, 0n)).to.be.revertedWith("not controller");
  });

  it("activates once, snapshotting the cap table split", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    expect(await controller.convertibleB()).to.equal((B_TOTAL * 7000n) / 10000n);
    expect(await controller.retainedB()).to.equal((B_TOTAL * 3000n) / 10000n);
    // Snapshotted after graduation burned the unsold A, so every A that exists can reach B.
    expect(await controller.aSupplyAtActivation()).to.equal(await f.share.totalSupply());
    expect(await controller.aSupplyAtActivation()).to.be.lt(SUPPLY * WAD);
    await expect(f.launchpad.activateController(0, B_TOTAL)).to.be.revertedWith("activated");
  });
});

describe("AgentController — the gates", () => {
  it("closes conversion for the whole grace period", async () => {
    const f = await deploy({ grace: 365n * 24n * 3600n });
    const controller = await attachController(f, { waitGrace: false });
    await (await f.kyc.setApproved(f.alice.address, true)).wait();

    await expect(convert(f, controller, f.alice, 100n)).to.be.revertedWith("grace period");

    await time.increase(365n * 24n * 3600n + 1n);
    await expect(convert(f, controller, f.alice, 100n)).to.not.be.reverted;
  });

  it("requires KYC at the crossing — and nowhere else", async () => {
    const f = await deploy();
    const controller = await attachController(f);

    // Trading A is permissionless: alice can buy and sell with no approval anywhere.
    expect(await f.kyc.isApproved(f.alice.address)).to.equal(false);
    await expect(convert(f, controller, f.alice, 100n)).to.be.revertedWith("kyc required");

    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    await expect(convert(f, controller, f.alice, 100n)).to.not.be.reverted;
  });
});

describe("AgentController — the crossing opens only after graduation", () => {
  it("refuses to activate while the curve is still selling", async () => {
    const f = await deploy();
    await attachController(f, { activate: false });
    await buy(f, f.alice, 1_000n);
    await expect(f.launchpad.activateController(0, B_TOTAL)).to.be.revertedWith("not graduated");
  });

  it("rations the convertible B — the pool cannot be over-drawn", async () => {
    // Retain the 50% cap: half of B is convertible.
    const f = await deploy({ retainedBps: 5000n });
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const [num, den] = await controller.conversionRate();
    expect(num).to.equal(await controller.convertibleB());
    expect(den).to.be.lt(await controller.aSupplyAtActivation()); // the curve's AMM-side A is excluded
    const per1k = (1_000n * WAD * num) / den;
    expect(await controller.quoteConversion(1_000n)).to.equal(per1k);
    await (await convert(f, controller, f.alice, 1_000n)).wait();
    expect(await f.bToken.balanceOf(f.alice.address)).to.be.closeTo(per1k, per1k / 1000n);
  });

  it("refuses a controller that retains everything (A would have no floor at all)", async () => {
    const f = await deploy({ retainedBps: 10000n });
    await expect(attachController(f, { activate: false })).to.be.reverted;
  });

  it("lets a request be cancelled while its batch collects, and not after it closes", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const before = await f.share.balanceOf(f.alice.address);
    const id = await request(f, controller, f.alice, 500n);
    await (await controller.connect(f.alice).cancelRequest(id, 200n)).wait();
    expect(await f.share.balanceOf(f.alice.address)).to.equal(before - 300n * WAD);
    await time.increase(COLLECT);
    await (await controller.poke()).wait();
    await expect(controller.connect(f.alice).cancelRequest(id, 100n)).to.be.revertedWith("batch closed");
    await expect(controller.connect(f.alice).claim(id)).to.be.revertedWith("not settled");
    expect(await controller.claimable(id, f.alice.address)).to.equal(0n);
    await time.increase(PRICING);
    const due = await controller.claimable(id, f.alice.address); // still 0: nobody settled it yet
    expect(due).to.equal(0n);
    await (await controller.connect(f.alice).claim(id)).wait();
    expect(await f.bToken.balanceOf(f.alice.address)).to.be.gt(0n);
    await expect(controller.connect(f.alice).claim(id)).to.be.revertedWith("nothing to claim");
  });
});

describe("AgentController — conversion after graduation", () => {
  async function graduated() {
    const f = await deploy({ gradRaise: GRAD_RAISE_LOW });
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
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
    const controller = await attachController(f, { waitGrace: false });
    expect(await controller.vestedRetained()).to.equal(0n);
    await expect(controller.releaseRetained()).to.be.revertedWith("nothing vested");
  });

  it("vests linearly after the cliff and pays out pull-based", async () => {
    const f = await deploy({ cliff: YEAR, vest: 2n * YEAR });
    const controller = await attachController(f, { waitGrace: false });
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
    await graduate(f);
    // A stranger front-runs with 1 wei of B and tries to open the crossing on it.
    await (await f.bToken.transfer(await controller.getAddress(), 1n)).wait();
    await expect(controller.connect(f.alice).activate(1n)).to.be.revertedWith("not activator");
    await expect(f.launchpad.connect(f.alice).activateController(0, 1n)).to.be.reverted;
    // The real B arrives; the owner activates on the stated amount, not on whatever is there.
    await (await f.bToken.transfer(await controller.getAddress(), B_TOTAL - 1n)).wait();
    await (await f.launchpad.activateController(0, B_TOTAL - 1n)).wait();
    expect(await controller.convertibleB()).to.equal(B_TOTAL - 1n - ((B_TOTAL - 1n) * 3000n) / 10000n);
  });

  it("returns B parked in a controller that was never activated, and only then", async () => {
    const f = await deploy();
    const controller = await attachController(f, { activate: false });
    await expect(f.launchpad.connect(f.alice).recoverControllerB(0)).to.be.reverted;
    await (await f.launchpad.recoverControllerB(0)).wait();
    expect(await f.bToken.balanceOf(f.creator.address)).to.equal(B_TOTAL);
    expect(await f.bToken.balanceOf(await controller.getAddress())).to.equal(0n);
    await (await f.bToken.connect(f.creator).transfer(await controller.getAddress(), B_TOTAL)).wait();
    await graduate(f);
    await (await f.launchpad.activateController(0, B_TOTAL)).wait();
    await expect(f.launchpad.recoverControllerB(0)).to.be.revertedWith("activated");
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
      retainedBps: 3000, graceSeconds: MIN_GRACE, cliffSeconds: 0, vestSeconds: 0,
    };
    await expect(f.launchpad.deployController(0, { ...base, graceSeconds: MIN_GRACE - 1n })).to.be.revertedWith("grace too short");
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

  it("counts A donated to the AMM as gone, never as the curve's own position", async () => {
    const f = await deploy({ gradRaise: GRAD_RAISE_LOW });
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const amm = await f.curve.amm();
    const [num0, den0] = await controller.conversionRate();
    await (await f.share.connect(f.alice).transfer(amm, 1_000n * WAD)).wait(); // donation
    const [num1, den1] = await controller.conversionRate();
    expect(num1).to.equal(num0);
    expect(den1).to.equal(den0 - 1_000n * WAD); // out of reach, like burned A — and nothing more
    await (await convert(f, controller, f.alice, 100n)).wait();
    expect(await f.bToken.balanceOf(f.alice.address)).to.be.closeTo((100n * WAD * num1) / den1, num1 / den1 * WAD / 1000n);
  });
});

describe("Hardening — precision, reachability and fixed roles", () => {
  it("lets the holders of every A outside the curve's pool reach all the convertible B", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const all = (await f.share.balanceOf(f.alice.address)) / WAD;
    await (await convert(f, controller, f.alice, all / 3n)).wait();
    await (await convert(f, controller, f.alice, (await f.share.balanceOf(f.alice.address)) / WAD)).wait();
    expect(await controller.bConverted()).to.equal(await controller.convertibleB());
  });

  it("splits a batch pro rata among its requesters, to the last unit of B", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    for (const u of [f.alice, f.bob]) await (await f.kyc.setApproved(u.address, true)).wait();
    await (await f.share.connect(f.alice).transfer(f.bob.address, 777n * WAD)).wait();
    const id = await request(f, controller, f.alice, 1_333n);
    expect(await request(f, controller, f.bob, 777n)).to.equal(id);
    expect(await controller.settlesAt(id)).to.be.gt(0n);
    await time.increase(COLLECT + PRICING);
    await (await controller.poke()).wait(); // closes it — pricing starts only now
    await expect(controller.connect(f.alice).claim(id)).to.be.revertedWith("not settled");
    await time.increase(PRICING);
    await (await controller.connect(f.bob).claim(id)).wait();
    await (await controller.connect(f.alice).claim(id)).wait();
    const a = await f.bToken.balanceOf(f.alice.address);
    const b = await f.bToken.balanceOf(f.bob.address);
    expect(a + b).to.equal((await controller.batches(id)).bOut);
    expect(a + b).to.equal(await controller.bConverted());
    expect(a * 777n).to.be.closeTo(b * 1_333n, 1_333n * 777n);
  });

  it("prices a batch only after it closes: a skew around the request moves nothing", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const amm = await ethers.getContractAt("AgentAMM", await f.curve.amm());
    const snap = await ethers.provider.send("evm_snapshot", []);
    await (await convert(f, controller, f.alice, 1_000n)).wait();
    const clean = await f.bToken.balanceOf(f.alice.address);
    await ethers.provider.send("evm_revert", [snap]);
    // bob buys A out of the pool right as alice requests, and unwinds before the batch closes.
    await (await f.dobx.connect(f.bob).approve(await amm.getAddress(), ethers.MaxUint256)).wait();
    await (await f.share.connect(f.bob).approve(await amm.getAddress(), ethers.MaxUint256)).wait();
    await (await amm.connect(f.bob).swapQuoteForShare(10n ** 21n, 0n, DL)).wait();
    const id = await request(f, controller, f.alice, 1_000n);
    await time.increase(COLLECT - 60n);
    await (await amm.connect(f.bob).swapShareForQuote(await f.share.balanceOf(f.bob.address), 0n, DL)).wait();
    await time.increase(60n);
    await (await controller.poke()).wait();
    await time.increase(PRICING);
    await (await controller.connect(f.alice).claim(id)).wait();
    expect(await f.bToken.balanceOf(f.alice.address)).to.be.closeTo(clean, clean / 200n);
  });

  it("an hour-long skew inside the pricing window moves the rate by roughly 1/24 of it", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const amm = await ethers.getContractAt("AgentAMM", await f.curve.amm());
    const snap = await ethers.provider.send("evm_snapshot", []);
    await (await convert(f, controller, f.alice, 1_000n)).wait();
    const clean = await f.bToken.balanceOf(f.alice.address);
    await ethers.provider.send("evm_revert", [snap]);
    const id = await request(f, controller, f.alice, 1_000n);
    await time.increase(COLLECT);
    await (await controller.poke()).wait();
    await (await f.dobx.connect(f.bob).approve(await amm.getAddress(), ethers.MaxUint256)).wait();
    await (await f.share.connect(f.bob).approve(await amm.getAddress(), ethers.MaxUint256)).wait();
    await (await amm.connect(f.bob).swapQuoteForShare(10n ** 21n, 0n, DL)).wait();
    await time.increase(3600n);
    await (await amm.connect(f.bob).swapShareForQuote(await f.share.balanceOf(f.bob.address), 0n, DL)).wait();
    await time.increase(PRICING - 3600n);
    await (await controller.connect(f.alice).claim(id)).wait();
    const got = await f.bToken.balanceOf(f.alice.address);
    const d = got > clean ? got - clean : clean - got;
    expect(d * 100n / clean).to.be.lt(5n);
  });

  it("a batch waits while the pool sits off its averages, and settles once they agree", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const amm = await ethers.getContractAt("AgentAMM", await f.curve.amm());
    const id = await request(f, controller, f.alice, 1_000n);
    await time.increase(COLLECT);
    await (await controller.poke()).wait();
    await time.increase(PRICING);
    await (await f.dobx.connect(f.bob).approve(await amm.getAddress(), ethers.MaxUint256)).wait();
    await (await amm.connect(f.bob).swapQuoteForShare(10n ** 21n, 0n, DL)).wait();
    await (await controller.poke()).wait();
    expect((await controller.batches(id)).settled).to.equal(false);
    await expect(controller.connect(f.alice).claim(id)).to.be.revertedWith("not settled");
    await time.increase(DAY + 1n);
    await (await controller.connect(f.alice).claim(id)).wait();
    expect(await f.bToken.balanceOf(f.alice.address)).to.be.gt(0n);
  });

  it("settles even if nobody claims for long, with a wider capex floor after the grace day", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const id = await request(f, controller, f.alice, 100n);
    await time.increase(COLLECT);
    await (await controller.poke()).wait();
    await time.increase(PRICING + 2n * DAY);
    await (await controller.connect(f.alice).claim(id)).wait();
    expect(await f.bToken.balanceOf(f.alice.address)).to.be.gt(0n);
    expect(await f.dobx.balanceOf(f.capexSink.address)).to.be.gt(0n);
  });

  it("refuses to bind B too coarse to split per whole A", async () => {
    const f = await deploy();
    await expect(attachController(f, { activate: false, seedB: 1000n, bSupply: 1000n })).to.be.revertedWith("B too coarse");
  });

  it("refuses a goal that would leave too little inventory to seed the AMM at the terminal price", async () => {
    const f = await deploy();
    const base = {
      name: "X", symbol: "X", supply: SUPPLY, basePrice: BASE_PRICE, slope: SLOPE,
      buyFeeBps: BUY_FEE, sellFeeBps: SELL_FEE, creator: f.creator.address, feeRecipient: ethers.ZeroAddress,
    };
    await expect(f.launchpad.launch({ ...base, graduationRaise: integral(0n, SUPPLY - 1n) })).to.be.revertedWith("grad too late");
    await expect(f.launchpad.launch({ ...base, graduationRaise: integral(0n, (SUPPLY * 9n) / 10n) })).to.be.revertedWith("grad too late");
    await (await f.launchpad.launch({ ...base, graduationRaise: integral(0n, SUPPLY / 2n) })).wait();
  });

  it("refuses a graduating buy that overshoots past what the inventory can seed", async () => {
    const f = await deploy();
    const cost = await f.curve.getBuyCost(999_000n);
    await (await f.dobx.connect(f.alice).approve(await f.curve.getAddress(), cost * 2n)).wait();
    await expect(f.curve.connect(f.alice).buy(999_000n, cost * 2n, DL)).to.be.revertedWith("seed short");
  });

  it("seeds the AMM at the terminal price", async () => {
    const f = await deploy();
    await graduate(f);
    const amm = await ethers.getContractAt("AgentAMM", await f.curve.amm());
    const spot = ((await amm.quoteReserve()) * WAD) / (await amm.shareReserve());
    const term = await f.curve.getCurrentPrice();
    const d = spot > term ? spot - term : term - spot;
    expect((d * 1000n) / term).to.be.lt(5n); // within 0.5%
    expect(await f.curve.inventory()).to.equal(0n);
  });

  it("does not inflate a release when A is parked as third-party liquidity", async () => {
    const f = await deploy();
    const controller = await attachController(f);
    await (await f.kyc.setApproved(f.alice.address, true)).wait();
    const amm = await ethers.getContractAt("AgentAMM", await f.curve.amm());
    const snap = await ethers.provider.send("evm_snapshot", []);
    await (await convert(f, controller, f.alice, 300n)).wait();
    const clean = await controller.capexFunded();
    await ethers.provider.send("evm_revert", [snap]);
    const shares = 5_000n * WAD;
    const quote = (shares * (await amm.quoteReserve())) / (await amm.shareReserve());
    await (await f.share.connect(f.alice).approve(await amm.getAddress(), shares)).wait();
    await (await f.dobx.connect(f.alice).approve(await amm.getAddress(), quote * 2n)).wait();
    await (await amm.connect(f.alice).addLiquidity(shares, quote * 2n, 0n, 0n, DL)).wait();
    await (await convert(f, controller, f.alice, 300n)).wait();
    expect(await controller.capexFunded()).to.be.closeTo(clean, clean / 1000n);
  });

  it("puts the treasury and, once agents exist, the KYC registry behind a 2-day timelock", async () => {
    const f = await deploy();
    const t0 = await f.launchpad.platformTreasury();
    await (await f.launchpad.setPlatformTreasury(f.bob.address)).wait();
    expect(await f.launchpad.platformTreasury()).to.equal(t0);
    await expect(f.launchpad.acceptPlatformTreasury()).to.be.revertedWith("timelocked");
    const k0 = await f.launchpad.kycRegistry();
    await (await f.launchpad.setKycRegistry(ethers.ZeroAddress)).wait(); // a launch exists → proposal
    expect(await f.launchpad.kycRegistry()).to.equal(k0);
    await expect(f.launchpad.acceptKycRegistry()).to.be.revertedWith("timelocked");
    await time.increase(2n * DAY);
    await (await f.launchpad.acceptPlatformTreasury()).wait();
    await (await f.launchpad.acceptKycRegistry()).wait();
    expect(await f.launchpad.platformTreasury()).to.equal(f.bob.address);
    expect(await f.launchpad.kycRegistry()).to.equal(ethers.ZeroAddress);
    await expect(f.launchpad.connect(f.alice).setPlatformTreasury(f.alice.address)).to.be.reverted;
  });

  it("the quote token is fixed for the launchpad's life", async () => {
    const f = await deploy();
    expect(f.launchpad.interface.fragments.some((fr) => fr.name === "setQuoteToken")).to.equal(false);
  });
});
