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
    await expect(stake.connect(stranger).requestWithdraw()).to.be.revertedWith("not operator");
    await expect(stake.connect(stranger).withdraw(1n)).to.be.revertedWith("not operator");
  });

  it("enforces the withdrawal cooldown", async () => {
    const { operator, stake } = await fixture();
    await stake.connect(operator).stake(10_000n * E6);
    await expect(stake.connect(operator).withdraw(1n)).to.be.revertedWith("cooldown"); // no request yet
    await stake.connect(operator).requestWithdraw();
    await expect(stake.connect(operator).withdraw(1n)).to.be.revertedWith("cooldown"); // too early
    await bump(COOLDOWN);
    await stake.connect(operator).withdraw(10_000n * E6);
    expect(await stake.staked()).to.equal(0n);
  });

  it("attester can slash to the beneficiary — even during the cooldown", async () => {
    const { operator, attester, insurance, stake, usdc } = await fixture();
    await stake.connect(operator).stake(10_000n * E6);
    await stake.connect(operator).requestWithdraw(); // operator tries to exit
    expect(await stake.withdrawalPending()).to.equal(true);

    // caught under-reporting before the cooldown matures → slashed
    await stake.connect(attester).slash(6_000n * E6, "under-reported x402 revenue");
    expect(await stake.staked()).to.equal(4_000n * E6);
    expect(await usdc.balanceOf(insurance.address)).to.equal(6_000n * E6);

    // operator can only ever withdraw what's left after slashing
    await bump(COOLDOWN);
    await stake.connect(operator).withdraw(4_000n * E6);
    await expect(stake.connect(operator).withdraw(1n)).to.be.reverted;
  });

  it("gates slash to attester/owner and bounds the amount", async () => {
    const { owner, operator, stranger, stake } = await fixture();
    await stake.connect(operator).stake(1_000n * E6);
    await expect(stake.connect(stranger).slash(1n, "x")).to.be.revertedWith("not attester");
    await expect(stake.connect(owner).slash(2_000n * E6, "too much")).to.be.revertedWith("bad amount");
    await stake.connect(owner).slash(1_000n * E6, "owner can slash");
    expect(await stake.staked()).to.equal(0n);
  });

  it("topping up recommits (cancels a pending withdrawal)", async () => {
    const { operator, stake } = await fixture();
    await stake.connect(operator).stake(1_000n * E6);
    await stake.connect(operator).requestWithdraw();
    expect(await stake.unlockAt()).to.be.gt(0n);
    await stake.connect(operator).stake(500n * E6);
    expect(await stake.unlockAt()).to.equal(0n); // recommitted
  });

  it("only owner manages attester/beneficiary/cooldown", async () => {
    const { owner, stranger, attester, stake } = await fixture();
    await expect(stake.connect(stranger).setAttester(stranger.address)).to.be.reverted;
    await stake.connect(owner).setAttester(stranger.address);
    expect(await stake.attester()).to.equal(stranger.address);
  });
});
