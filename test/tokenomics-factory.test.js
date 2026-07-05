const { expect } = require("chai");
const { ethers } = require("hardhat");

const E18 = 10n ** 18n;
const E6 = 10n ** 6n;
const DL = ethers.MaxUint256;

async function fixture() {
  const [owner, lp, keeper] = await ethers.getSigners();
  const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
  const Share = await ethers.getContractFactory("AgentShareToken");
  const tokenA = await Share.deploy("Agent A", "A", 1_000_000n * E18, lp.address, 18);
  const tokenB = await Share.deploy("Dist B", "B", 1_000_000n * E18, owner.address, 18);

  const amm = await (await ethers.getContractFactory("AgentAMM")).deploy(
    await tokenA.getAddress(), await usdc.getAddress(),
  );
  await usdc.mint(lp.address, 100_000n * E6);
  await tokenA.connect(lp).approve(await amm.getAddress(), 100_000n * E18);
  await usdc.connect(lp).approve(await amm.getAddress(), 100_000n * E6);
  await amm.connect(lp).addLiquidity(100_000n * E18, 100_000n * E6, 0, 0, DL);

  const factory = await (await ethers.getContractFactory("TokenomicsFactory")).deploy();
  return { owner, lp, keeper, usdc, tokenA, tokenB, amm, factory };
}

const THROTTLE = { maxSpendPerEpoch: 1_000n * E6, epochLength: 3600, minInterval: 60 };

describe("TokenomicsFactory — deploys + wires the trio", () => {
  it("deploys treasury + buyback + converter wired to the AMM/tokens", async () => {
    const { owner, tokenA, tokenB, amm, factory } = await fixture();
    const [treasury, buyback, converter] = await factory.deploy.staticCall(
      await tokenA.getAddress(), await amm.getAddress(), await tokenB.getAddress(),
      owner.address, 100, THROTTLE,
    );
    await factory.deploy(
      await tokenA.getAddress(), await amm.getAddress(), await tokenB.getAddress(),
      owner.address, 100, THROTTLE,
    );

    const t = await ethers.getContractAt("AgentTreasury", treasury);
    const b = await ethers.getContractAt("AgentBuyback", buyback);
    const c = await ethers.getContractAt("AgentConverter", converter);

    // treasury holds A (locked) + B
    expect(await t.agentToken()).to.equal(await tokenA.getAddress());
    expect(await t.distToken()).to.equal(await tokenB.getAddress());
    expect(await t.owner()).to.equal(owner.address);

    // buyback wired to amm + treasury, throttle applied, owner set
    expect(await b.amm()).to.equal(await amm.getAddress());
    expect(await b.treasury()).to.equal(treasury);
    expect(await b.agentToken()).to.equal(await tokenA.getAddress());
    expect(await b.maxSpendPerEpoch()).to.equal(THROTTLE.maxSpendPerEpoch);
    expect(await b.owner()).to.equal(owner.address);

    // converter wired to amm + treasury with the fee
    expect(await c.amm()).to.equal(await amm.getAddress());
    expect(await c.treasury()).to.equal(treasury);
    expect(await c.feeBps()).to.equal(100n);
    expect(await c.owner()).to.equal(owner.address);
  });

  it("owner can then authorize the buyback keeper and it works end-to-end", async () => {
    const { owner, keeper, usdc, tokenA, tokenB, amm, factory } = await fixture();
    const [treasury, buyback] = await factory.deploy.staticCall(
      await tokenA.getAddress(), await amm.getAddress(), await tokenB.getAddress(),
      owner.address, 100, THROTTLE,
    );
    await factory.deploy(
      await tokenA.getAddress(), await amm.getAddress(), await tokenB.getAddress(),
      owner.address, 100, THROTTLE,
    );
    const b = await ethers.getContractAt("AgentBuyback", buyback);
    await b.connect(owner).setKeeper(keeper.address);

    // fund + fire a tranche
    await usdc.mint(owner.address, 500n * E6);
    await usdc.connect(owner).approve(buyback, 500n * E6);
    await b.connect(owner).deposit(500n * E6);
    await b.connect(keeper).executeBuyback(200n * E6, 0, DL);

    const t = await ethers.getContractAt("AgentTreasury", treasury);
    expect(await t.agentHeld()).to.be.gt(0n); // bought A landed in the treasury
  });

  it("rejects an AMM whose share token is not the agent token", async () => {
    const { owner, tokenB, amm, factory } = await fixture();
    await expect(
      factory.deploy(await tokenB.getAddress(), await amm.getAddress(), await tokenB.getAddress(),
        owner.address, 100, THROTTLE),
    ).to.be.revertedWith("amm/token mismatch");
  });

  it("rejects zero addresses", async () => {
    const { owner, tokenA, tokenB, amm, factory } = await fixture();
    await expect(
      factory.deploy(await tokenA.getAddress(), await amm.getAddress(), ethers.ZeroAddress,
        owner.address, 100, THROTTLE),
    ).to.be.revertedWith("zero addr");
  });
});
