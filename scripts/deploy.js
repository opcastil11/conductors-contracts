const { ethers, network } = require("hardhat");

/**
 * Deploys the AgentLaunchpad. The quote token (USDC) and platform treasury come from env.
 * On a network without a real USDC (e.g. a fresh testnet), pass USE_MOCK_USDC=1 to deploy
 * a MockUSDC first.
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address} on ${network.name}`);

  let quote = process.env.QUOTE_TOKEN;
  if (process.env.USE_MOCK_USDC === "1" || !quote) {
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();
    quote = await usdc.getAddress();
    console.log(`MockUSDC: ${quote}`);
  }

  const treasury = process.env.PLATFORM_TREASURY || deployer.address;

  const Launchpad = await ethers.getContractFactory("AgentLaunchpad");
  const launchpad = await Launchpad.deploy(deployer.address, quote, treasury);
  await launchpad.waitForDeployment();

  console.log(`AgentLaunchpad: ${await launchpad.getAddress()}`);
  console.log(`  quoteToken:       ${quote}`);
  console.log(`  platformTreasury: ${treasury}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
