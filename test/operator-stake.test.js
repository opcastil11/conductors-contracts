const { expect } = require("chai");
const { ethers } = require("hardhat");

const E6 = 10n ** 6n;

async function bump(secs) {
  await ethers.provider.send("evm_increaseTime", [secs]);
  await ethers.provider.send("evm_mine", []);
}

const COOLDOWN = 7 * 24 * 3600; // 7 days

async function fixture() {
  const [owner, operator, attester, insurance, stranger] = await ethers.getSigners();
  const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
  const stake = await (await ethers.getContractFactory("OperatorStake")).deploy(
    await usdc.getAddress(), operator.address, attester.address, insurance.address, COOLDOWN, owner.address,
  );
  await usdc.mint(operator.address, 100_000n * E6);
  await usdc.connect(operator).approve(await stake.getAddress(), ethers.MaxUint256);
  return { owner, operator, attester, insurance, stranger, usdc, stake };
}

describe("OperatorStake — bond + slash for revenue under-reporting", () => {
  it("operator posts a bond", async () => {
    const { operator, stake, usdc } = await fixture();
    await stake.connect(operator).stake(10_000n * E6);
    expect(await stake.staked()).to.equal(10_000n * E6);
    expect(await usdc.balanceOf(await stake.getAddress())).to.equal(10_000n * E6);
  });

  it("only the operator can stake / request / withdraw", async () => {
    const { stranger, stake } = await fixture();
    await expect(stake.connect(stranger).stake(1n)).to.be.revertedWith("not operator");
    await expect(stake.connect(stranger).requestWithdraw(1n)).to.be.revertedWith("not operator");
    await expect(stake.connect(stranger).withdraw()).to.be.revertedWith("not operator");
  });

  it("enforces the withdrawal cooldown", async () => {
    const { operator, stake } = await fixture();
    await stake.connect(operator).stake(10_000n * E6);
    await expect(stake.connect(operator).withdraw()).to.be.revertedWith("cooldown"); // no request yet
    await stake.connect(operator).requestWithdraw(10_000n * E6);
    await expect(stake.connect(operator).withdraw()).to.be.revertedWith("cooldown"); // too early
    await bump(COOLDOWN);
    await stake.connect(operator).withdraw();
    expect(await stake.staked()).to.equal(0n);
  });

  it("attester can slash to the beneficiary — even during the cooldown", async () => {
    const { operator, attester, insurance, stake, usdc } = await fixture();
    await stake.connect(operator).stake(10_000n * E6);
    await stake.connect(operator).requestWithdraw(10_000n * E6); // operator tries to exit
    expect(await stake.withdrawalPending()).to.equal(true);

    // caught under-reporting before the cooldown matures → slashed
    await stake.connect(attester).slash(6_000n * E6, "under-reported x402 revenue");
    expect(await stake.staked()).to.equal(4_000n * E6);
    expect(await usdc.balanceOf(insurance.address)).to.equal(6_000n * E6);

    // the slash cancelled the request: the operator must ask again and wait a full cooldown
    expect(await stake.unlockAt()).to.equal(0n);
    await bump(COOLDOWN);
    await expect(stake.connect(operator).withdraw()).to.be.revertedWith("cooldown");
    await stake.connect(operator).requestWithdraw(4_000n * E6);
    await bump(COOLDOWN);
    await stake.connect(operator).withdraw();
    await expect(stake.connect(operator).withdraw()).to.be.reverted;
  });

  it("gates slash to the attester only (not the owner) and bounds the amount", async () => {
    const { owner, operator, attester, stranger, stake } = await fixture();
    await stake.connect(operator).stake(1_000n * E6);
    await expect(stake.connect(stranger).slash(1n, "x")).to.be.revertedWith("not attester");
    await expect(stake.connect(owner).slash(1n, "x")).to.be.revertedWith("not attester");
    // Over-asking clamps to the stake, so a 1-wei withdrawal cannot dodge an exact-amount slash.
    await stake.connect(attester).slash(2_000n * E6, "clamped");
    expect(await stake.staked()).to.equal(0n);
    expect(await stake.staked()).to.equal(0n);
  });

  it("topping up recommits (cancels a pending withdrawal)", async () => {
    const { operator, stake } = await fixture();
    await stake.connect(operator).stake(1_000n * E6);
    await stake.connect(operator).requestWithdraw(1_000n * E6);
    expect(await stake.unlockAt()).to.be.gt(0n);
    await stake.connect(operator).stake(500n * E6);
    expect(await stake.unlockAt()).to.equal(0n); // recommitted
  });

  it("a matured request lapses after the window — no standing exit permission", async () => {
    const { operator, stake } = await fixture();
    await stake.connect(operator).stake(1_000n * E6);
    await stake.connect(operator).requestWithdraw(400n * E6);
    await bump(COOLDOWN + 7 * 86400 + 1);
    await expect(stake.connect(operator).withdraw()).to.be.revertedWith("request lapsed");
    await stake.connect(operator).requestWithdraw(400n * E6);
    await bump(COOLDOWN);
    await stake.connect(operator).withdraw();
    expect(await stake.staked()).to.equal(600n * E6); // only the amount fixed at request time
  });

  it("only the owner rotates the attester, and only after the timelock", async () => {
    const { owner, stranger, attester, stake } = await fixture();
    await expect(stake.connect(stranger).setAttester(stranger.address)).to.be.reverted;
    await stake.connect(owner).setAttester(stranger.address);
    expect(await stake.attester()).to.equal(attester.address);
    await expect(stake.connect(owner).acceptAttester()).to.be.revertedWith("timelocked");
    await ethers.provider.send("evm_increaseTime", [2 * 24 * 3600]);
    await ethers.provider.send("evm_mine", []);
    await stake.connect(owner).acceptAttester();
    expect(await stake.attester()).to.equal(stranger.address);
  });

  it("the attester can hold a matured exit while it builds a case, bounded, without voiding it", async () => {
    const { owner, operator, attester, stranger, stake } = await fixture();
    await stake.connect(operator).stake(10_000n * E6);
    await stake.connect(operator).requestWithdraw(10_000n * E6);
    await bump(COOLDOWN);
    await expect(stake.connect(stranger).freeze(86400, "x")).to.be.revertedWith("not attester");
    await expect(stake.connect(owner).freeze(86400, "x")).to.be.revertedWith("not attester");
    await expect(stake.connect(attester).freeze(31 * 86400, "x")).to.be.revertedWith("freeze too long");
    await stake.connect(attester).freeze(30 * 86400, "reviewing reports");
    await expect(stake.connect(operator).withdraw()).to.be.reverted;
    await bump(30 * 86400);
    await stake.connect(operator).withdraw(); // the request re-armed from the freeze's end
    expect(await stake.staked()).to.equal(0n);
  });

  it("a new cooldown applies only after a week of notice", async () => {
    const { owner, stranger, stake } = await fixture();
    await expect(stake.connect(stranger).setCooldown(1)).to.be.reverted;
    await stake.connect(owner).setCooldown(1);
    expect(await stake.cooldown()).to.equal(COOLDOWN);
    await expect(stake.connect(owner).acceptCooldown()).to.be.revertedWith("timelocked");
    await bump(7 * 24 * 3600);
    await stake.connect(owner).acceptCooldown();
    expect(await stake.cooldown()).to.equal(1n);
  });
});
