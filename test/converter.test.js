const { expect } = require("chai");
const { ethers } = require("hardhat");

const E18 = 10n ** 18n;
const E6 = 10n ** 6n;
const DL = ethers.MaxUint256;

// AMM seeded so 1 whole A ≈ 1 whole USDC (100k A : 100k USDC).
async function fixture(feeBps = 100n) {
  const [owner, lp, alice] = await ethers.getSigners();

  const usdc = await (await ethers.getContractFactory("MockUSDC")).deploy();
  const Share = await ethers.getContractFactory("AgentShareToken");
  const tokenA = await Share.deploy("Agent A", "A", 1_000_000n * E18, lp.address, 18);
  const tokenB = await Share.deploy("Dist B", "B", 1_000_000n * E18, owner.address, 18);

  const amm = await (await ethers.getContractFactory("AgentAMM")).deploy(
    await tokenA.getAddress(), await usdc.getAddress(),
  );

  // seed liquidity from lp
  await usdc.mint(lp.address, 100_000n * E6);
  await tokenA.connect(lp).approve(await amm.getAddress(), 100_000n * E18);
  await usdc.connect(lp).approve(await amm.getAddress(), 100_000n * E6);
  await amm.connect(lp).addLiquidity(100_000n * E18, 100_000n * E6, 0, 0, DL);

  const treasury = await (await ethers.getContractFactory("AgentTreasury")).deploy(
    await tokenA.getAddress(), await tokenB.getAddress(), owner.address,
  );

  const converter = await (await ethers.getContractFactory("AgentConverter")).deploy(
    await amm.getAddress(), await treasury.getAddress(), feeBps, owner.address,
  );

  // alice gets some A to convert
  await tokenA.connect(lp).transfer(alice.address, 10_000n * E18);

  return { owner, lp, alice, usdc, tokenA, tokenB, amm, treasury, converter };
}

describe("AgentConverter — sell A for USDC, skim convert fee to treasury (no oracle)", () => {
  it("wires token addresses from the AMM", async () => {
    const { converter, tokenA, usdc } = await fixture();
    expect(await converter.agentToken()).to.equal(await tokenA.getAddress());
    expect(await converter.quoteToken()).to.equal(await usdc.getAddress());
  });

  it("converts A→USDC: user gets net, treasury gets the fee, no dust", async () => {
    const { alice, treasury, usdc, tokenA, amm, converter } = await fixture(100n); // 1%
    const aIn = 1_000n * E18;

    const gross = await amm.quoteForShare(aIn);
    const fee = (gross * 100n) / 10_000n;
    const net = gross - fee;

    await tokenA.connect(alice).approve(await converter.getAddress(), aIn);
    await converter.connect(alice).convert(aIn, 0, DL);

    expect(await usdc.balanceOf(alice.address)).to.equal(net);
    expect(await usdc.balanceOf(await treasury.getAddress())).to.equal(fee);
    expect(await usdc.balanceOf(await converter.getAddress())).to.equal(0n); // nothing stuck
    expect(fee + net).to.equal(gross);
  });

  it("with zero fee, all proceeds go to the user", async () => {
    const { alice, treasury, usdc, tokenA, amm, converter } = await fixture(0n);
    const aIn = 500n * E18;
    const gross = await amm.quoteForShare(aIn);

    await tokenA.connect(alice).approve(await converter.getAddress(), aIn);
    await converter.connect(alice).convert(aIn, 0, DL);

    expect(await usdc.balanceOf(alice.address)).to.equal(gross);
    expect(await usdc.balanceOf(await treasury.getAddress())).to.equal(0n);
  });

  it("honors net-out slippage and requires aIn>0", async () => {
    const { alice, tokenA, amm, converter } = await fixture(100n);
    const aIn = 1_000n * E18;
    const gross = await amm.quoteForShare(aIn);
    await tokenA.connect(alice).approve(await converter.getAddress(), aIn);
    // demand more net than possible
    await expect(converter.connect(alice).convert(aIn, gross, DL)).to.be.revertedWith("slippage");
    await expect(converter.connect(alice).convert(0, 0, DL)).to.be.revertedWith("aIn>0");
  });

  it("is one-way: no B→A / redeem path", async () => {
    const { converter } = await fixture();
    const fns = converter.interface.fragments.filter((f) => f.type === "function").map((f) => f.name);
    expect(fns).to.include("convert");
    expect(fns).to.not.include("redeem");
    expect(fns).to.not.include("convertBack");
  });

  it("caps and gates the fee", async () => {
    const { owner, alice, converter } = await fixture(100n);
    await expect(
      (await ethers.getContractFactory("AgentConverter")).deploy(
        await converter.amm(), await converter.treasury(), 201, owner.address,
      ),
    ).to.be.revertedWith("fee too high");
    await expect(converter.connect(alice).setFeeBps(50)).to.be.reverted; // not owner
    await expect(converter.connect(owner).setFeeBps(300)).to.be.revertedWith("fee too high");
    await converter.connect(owner).setFeeBps(50);
    expect(await converter.feeBps()).to.equal(50n);
  });
});
