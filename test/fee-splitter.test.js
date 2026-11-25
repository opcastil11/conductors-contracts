const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const USDC = (n) => BigInt(Math.round(n * 1e6));
const DL = ethers.MaxUint256;

async function fixture() {
  const [owner, platform, agent, alice, stranger] = await ethers.getSigners();
  const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
  const splitter = await (await ethers.getContractFactory("AgentFeeSplitter")).deploy(
    await usdc.getAddress(), agent.address, platform.address, 6500, owner.address,
  );
  return { owner, platform, agent, alice, stranger, usdc, splitter };
}

describe("AgentFeeSplitter — A's trading fees, agent 65 / platform 35", () => {
  it("splits the quote token at the ratio, permissionless", async () => {
    const { platform, agent, stranger, usdc, splitter } = await fixture();
    await usdc.mint(await splitter.getAddress(), USDC(100));
    expect(await splitter.pending()).to.deep.equal([USDC(65), USDC(35)]);
    await splitter.connect(stranger).release(await usdc.getAddress());
    expect(await usdc.balanceOf(agent.address)).to.equal(USDC(65));
    expect(await usdc.balanceOf(platform.address)).to.equal(USDC(35));
    expect(await usdc.balanceOf(await splitter.getAddress())).to.equal(0n);
  });

  it("sends any other token to the platform whole", async () => {
    const { platform, agent, splitter } = await fixture();
    const other = await (await ethers.getContractFactory("MockUSDC")).deploy();
    await other.mint(await splitter.getAddress(), 1000n);
    await splitter.release(await other.getAddress());
    expect(await other.balanceOf(platform.address)).to.equal(1000n);
    expect(await other.balanceOf(agent.address)).to.equal(0n);
  });

  it("only the owner moves the ratio, never below half to the agent", async () => {
    const { owner, stranger, splitter } = await fixture();
    await expect(splitter.connect(stranger).setAgentBps(7000)).to.be.reverted;
    await expect(splitter.connect(owner).setAgentBps(4999)).to.be.revertedWith("bad bps");
    await expect(splitter.connect(owner).setAgentBps(10001)).to.be.revertedWith("bad bps");
    const before = await splitter.agentBps();
    await splitter.connect(owner).setAgentBps(8000);
    expect(await splitter.agentBps()).to.equal(before); // announced, not applied
    await expect(splitter.connect(owner).acceptAgentBps()).to.be.revertedWith("timelocked");
    await expect(splitter.connect(stranger).acceptAgentBps()).to.be.reverted;
    await time.increase(2 * 86400);
    await splitter.connect(owner).acceptAgentBps();
    expect(await splitter.agentBps()).to.equal(8000);
  });

  it("only the agent rotates its own payee — not the owner, not a stranger", async () => {
    const { owner, agent, alice, stranger, splitter } = await fixture();
    await expect(splitter.connect(stranger).setAgent(stranger.address)).to.be.revertedWith("not agent");
    await expect(splitter.connect(owner).setAgent(owner.address)).to.be.revertedWith("not agent");
    await splitter.connect(agent).setAgent(alice.address);
    expect(await splitter.agent()).to.equal(alice.address);
  });

  it("works as a curve's explicit feeRecipient", async () => {
    const { owner, platform, agent, alice, usdc, splitter } = await fixture();
    const launchpad = await (await ethers.getContractFactory("AgentLaunchpad"))
      .deploy(owner.address, await usdc.getAddress(), platform.address);
    await (await launchpad.launch({
      name: "Apumail", symbol: "APU", supply: 1_000_000n, basePrice: 50_000n,
      slope: 100n, buyFeeBps: 100n, sellFeeBps: 100n, graduationRaise: 50_000_000n,
      creator: agent.address, feeRecipient: await splitter.getAddress(),
    })).wait();
    const curve = await ethers.getContractAt("AgentBondingCurve", (await launchpad.getLaunch(0)).curve);
    expect(await curve.feeRecipient()).to.equal(await splitter.getAddress());

    await usdc.mint(alice.address, USDC(1000));
    await usdc.connect(alice).approve(await curve.getAddress(), ethers.MaxUint256);
    await curve.connect(alice).buy(100n, ethers.MaxUint256, DL);
    const fees = await usdc.balanceOf(await splitter.getAddress());
    expect(fees).to.be.gt(0n);
    await splitter.release(await usdc.getAddress());
    expect(await usdc.balanceOf(agent.address)).to.equal((fees * 6500n) / 10000n);
  });
});
