const { expect } = require("chai");
const { ethers } = require("hardhat");

const E18 = 10n ** 18n;

async function fixture() {
  const [owner, alice] = await ethers.getSigners();
  const Share = await ethers.getContractFactory("AgentShareToken");
  const tokenA = await Share.deploy("Agent A", "A", 1_000_000n * E18, owner.address, 18);
  const tokenB = await Share.deploy("Dist B", "B", 1_000_000n * E18, owner.address, 18);
  const misc = await (await ethers.getContractFactory("MockUSDC")).deploy();

  const treasury = await (await ethers.getContractFactory("AgentTreasury")).deploy(
    await tokenA.getAddress(), await tokenB.getAddress(), owner.address,
  );

  // fund the treasury with A (sink), B (reserve) and some USDC (fees)
  await tokenA.connect(owner).transfer(await treasury.getAddress(), 10_000n * E18);
  await tokenB.connect(owner).transfer(await treasury.getAddress(), 500_000n * E18);
  await misc.mint(await treasury.getAddress(), 1_000_000n);

  return { owner, alice, tokenA, tokenB, misc, treasury };
}

describe("AgentTreasury — A locked, B/other deployable", () => {
  it("permanently locks the agent token A (no path out)", async () => {
    const { treasury, tokenA, alice } = await fixture();
    await expect(
      treasury.deploy(await tokenA.getAddress(), alice.address, 1n),
    ).to.be.revertedWith("agent token locked");
    expect(await treasury.agentHeld()).to.equal(10_000n * E18);
  });

  it("lets the owner deploy the B reserve (marketplace backstop / incentives)", async () => {
    const { owner, alice, treasury, tokenB } = await fixture();
    await treasury.connect(owner).deploy(await tokenB.getAddress(), alice.address, 100_000n * E18);
    expect(await tokenB.balanceOf(alice.address)).to.equal(100_000n * E18);
    expect(await treasury.distHeld()).to.equal(400_000n * E18);
  });

  it("lets the owner route other tokens (e.g. USDC convert fees)", async () => {
    const { owner, alice, treasury, misc } = await fixture();
    await treasury.connect(owner).deploy(await misc.getAddress(), alice.address, 1_000_000n);
    expect(await misc.balanceOf(alice.address)).to.equal(1_000_000n);
  });

  it("gates deploy to the owner and validates args", async () => {
    const { owner, alice, treasury, tokenB } = await fixture();
    await expect(
      treasury.connect(alice).deploy(await tokenB.getAddress(), alice.address, 1n),
    ).to.be.reverted; // not owner
    await expect(
      treasury.connect(owner).deploy(await tokenB.getAddress(), ethers.ZeroAddress, 1n),
    ).to.be.revertedWith("bad args");
    await expect(
      treasury.connect(owner).deploy(await tokenB.getAddress(), alice.address, 0n),
    ).to.be.revertedWith("bad args");
  });
});
