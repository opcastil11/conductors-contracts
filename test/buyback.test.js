const { expect } = require("chai");
const { ethers } = require("hardhat");

const E18 = 10n ** 18n;
const E6 = 10n ** 6n;
const DL = ethers.MaxUint256;

async function bump(secs) {
  await ethers.provider.send("evm_increaseTime", [secs]);
  await ethers.provider.send("evm_mine", []);
}

// maxSpendPerEpoch = 1000 USDC, epoch = 3600s, minInterval = 60s
async function fixture() {
  const [owner, lp, keeper, funder, alice] = await ethers.getSigners();

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

  const treasury = await (await ethers.getContractFactory("AgentTreasury")).deploy(
    await tokenA.getAddress(), await tokenB.getAddress(), owner.address,
  );

  const buyback = await (await ethers.getContractFactory("AgentBuyback")).deploy(
    await amm.getAddress(), await treasury.getAddress(), owner.address,
    1_000n * E6, 3600, 60,
  );
  await buyback.connect(owner).setKeeper(keeper.address);

  // fund the buyback with 5000 USDC
  await usdc.mint(funder.address, 5_000n * E6);
  await usdc.connect(funder).approve(await buyback.getAddress(), 5_000n * E6);
  await buyback.connect(funder).deposit(5_000n * E6);

  return { owner, lp, keeper, funder, alice, usdc, tokenA, tokenB, amm, treasury, buyback };
}

describe("AgentBuyback — TWAP tranches, A retired to the treasury", () => {
  it("buys A with USDC and sends it to the treasury; tracks epoch spend", async () => {
    const { keeper, treasury, buyback } = await fixture();
    await buyback.connect(keeper).executeBuyback(500n * E6, 0, DL);

    expect(await treasury.agentHeld()).to.be.gt(0n);
    expect(await buyback.spentThisEpoch()).to.equal(500n * E6);
    expect(await buyback.funds()).to.equal(4_500n * E6);
  });

  it("enforces the min interval between tranches", async () => {
    const { keeper, buyback } = await fixture();
    await buyback.connect(keeper).executeBuyback(100n * E6, 0, DL);
    await expect(buyback.connect(keeper).executeBuyback(100n * E6, 0, DL)).to.be.revertedWith("too soon");
    await bump(60);
    await buyback.connect(keeper).executeBuyback(100n * E6, 0, DL); // ok now
    expect(await buyback.spentThisEpoch()).to.equal(200n * E6);
  });

  it("enforces the per-epoch spend cap", async () => {
    const { keeper, buyback } = await fixture();
    await buyback.connect(keeper).executeBuyback(600n * E6, 0, DL);
    await bump(60);
    // 600 already spent this epoch; +500 would exceed the 1000 cap
    await expect(buyback.connect(keeper).executeBuyback(500n * E6, 0, DL)).to.be.revertedWith("epoch cap");
    await bump(60);
    await buyback.connect(keeper).executeBuyback(400n * E6, 0, DL); // 600+400 = 1000, exactly the cap
    expect(await buyback.spentThisEpoch()).to.equal(1_000n * E6);
  });

  it("rolls the epoch and refreshes the budget after epochLength", async () => {
    const { keeper, buyback } = await fixture();
    await buyback.connect(keeper).executeBuyback(1_000n * E6, 0, DL); // exhaust epoch
    expect(await buyback.epochBudgetRemaining()).to.equal(0n);
    await bump(3600); // next epoch
    expect(await buyback.epochBudgetRemaining()).to.equal(1_000n * E6);
    await buyback.connect(keeper).executeBuyback(300n * E6, 0, DL);
    expect(await buyback.spentThisEpoch()).to.equal(300n * E6);
  });

  it("rejects spending more than the available funds", async () => {
    const { keeper, buyback } = await fixture();
    // 5000 funded; asking for 6000 trips the funds guard (checked before the epoch cap)
    await expect(buyback.connect(keeper).executeBuyback(6_000n * E6, 0, DL)).to.be.revertedWith("insufficient funds");
  });

  it("only keeper or owner can execute", async () => {
    const { owner, alice, keeper, buyback } = await fixture();
    await expect(buyback.connect(alice).executeBuyback(100n * E6, 0, DL)).to.be.revertedWith("not keeper");
    await buyback.connect(owner).executeBuyback(100n * E6, 0, DL); // owner allowed
    await bump(60);
    await buyback.connect(keeper).executeBuyback(100n * E6, 0, DL); // keeper allowed
  });

  it("has no path to sell A back out of the treasury", async () => {
    const { treasury, tokenA, alice } = await fixture();
    await expect(
      treasury.deploy(await tokenA.getAddress(), alice.address, 1n),
    ).to.be.revertedWith("agent token locked");
  });
});
