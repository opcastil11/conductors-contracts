const { expect } = require("chai");
const { ethers } = require("hardhat");

const WAD = 10n ** 18n;
const DL = ethers.MaxUint256;

// A and B are both fixed-supply share tokens (B stands in for the DobProtocol participation token).
async function fixture(maxStaleness = 0) {
  const [owner, treasury, alice, updater] = await ethers.getSigners();
  const Share = await ethers.getContractFactory("AgentShareToken");
  const tokenA = await Share.deploy("Agent A", "A", 1_000_000n * WAD, alice.address, 18); // alice holds A
  const tokenB = await Share.deploy("Distribution B", "B", 1_000_000n * WAD, owner.address, 18); // owner holds B reserve

  const conversion = await (await ethers.getContractFactory("AgentConversion")).deploy(
    await tokenA.getAddress(), await tokenB.getAddress(),
    treasury.address, owner.address, updater.address, maxStaleness,
  );

  // owner funds the B reserve
  await tokenB.connect(owner).approve(await conversion.getAddress(), 500_000n * WAD);
  await conversion.connect(owner).fundReserve(500_000n * WAD);

  return { owner, treasury, alice, updater, tokenA, tokenB, conversion };
}

describe("AgentConversion — one-way A→B, NAV-anchored, reserve-bounded", () => {
  it("converts A into B at the set rate; A sinks to treasury, B leaves the reserve", async () => {
    const { alice, treasury, updater, tokenA, tokenB, conversion } = await fixture();
    await conversion.connect(updater).setRate(WAD); // 1:1

    await tokenA.connect(alice).approve(await conversion.getAddress(), 100n * WAD);
    const bOut = await conversion.quote(100n * WAD);
    expect(bOut).to.equal(100n * WAD);

    await conversion.connect(alice).convert(100n * WAD, bOut, DL);

    expect(await tokenB.balanceOf(alice.address)).to.equal(100n * WAD);   // received B
    expect(await tokenA.balanceOf(treasury.address)).to.equal(100n * WAD); // A sunk to treasury
    expect(await conversion.bReserve()).to.equal(500_000n * WAD - 100n * WAD);
  });

  it("prices with the NAV rate (B per A scaled 1e18)", async () => {
    const { alice, updater, tokenA, conversion } = await fixture();
    await conversion.connect(updater).setRate(WAD / 2n); // 1 A → 0.5 B (A worth less than B)
    await tokenA.connect(alice).approve(await conversion.getAddress(), 200n * WAD);
    expect(await conversion.quote(200n * WAD)).to.equal(100n * WAD);
    await conversion.connect(alice).convert(200n * WAD, 100n * WAD, DL);
  });

  it("halts when the reserve is depleted (protects B yield — no unbounded mint)", async () => {
    const { alice, updater, tokenA, conversion } = await fixture();
    await conversion.connect(updater).setRate(WAD);
    await tokenA.connect(alice).approve(await conversion.getAddress(), 1_000_000n * WAD);
    // reserve is 500k B; converting 600k A at 1:1 needs 600k B → must revert
    await expect(conversion.connect(alice).convert(600_000n * WAD, 0n, DL))
      .to.be.revertedWith("reserve depleted");
  });

  it("is one-way: there is no B→A conversion path", async () => {
    const { conversion } = await fixture();
    const fns = conversion.interface.fragments.filter((f) => f.type === "function").map((f) => f.name);
    expect(fns).to.include("convert");
    expect(fns).to.not.include("convertBack");
    expect(fns).to.not.include("redeem");
  });

  it("rejects an unset or stale rate", async () => {
    const { alice, updater, tokenA, conversion } = await fixture(100); // 100s staleness
    await tokenA.connect(alice).approve(await conversion.getAddress(), 100n * WAD);
    // unset rate
    await expect(conversion.connect(alice).convert(10n * WAD, 0n, DL)).to.be.revertedWith("no rate");
    // set, then let it go stale
    await conversion.connect(updater).setRate(WAD);
    await ethers.provider.send("evm_increaseTime", [200]);
    await ethers.provider.send("evm_mine", []);
    await expect(conversion.connect(alice).convert(10n * WAD, 0n, DL)).to.be.revertedWith("stale rate");
  });

  it("honors slippage and deadline; only updater/owner can set the rate", async () => {
    const { alice, updater, tokenA, conversion } = await fixture();
    await conversion.connect(updater).setRate(WAD);
    await tokenA.connect(alice).approve(await conversion.getAddress(), 100n * WAD);
    await expect(conversion.connect(alice).convert(10n * WAD, 11n * WAD, DL)).to.be.revertedWith("slippage");
    await expect(conversion.connect(alice).convert(10n * WAD, 0n, 1n)).to.be.revertedWith("expired");
    await expect(conversion.connect(alice).setRate(WAD)).to.be.revertedWith("not updater");
  });
});
