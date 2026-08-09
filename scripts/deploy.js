const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploys the platform layer of the one-way model (docs/TOKENOMICS-V2.md):
 *
 *   DOBX          — the quote token of every curve. Deployed here unless DOBX_ADDRESS is set;
 *                   the whole supply goes to PLATFORM_TREASURY.
 *   KycRegistry   — the allowlist consulted at the A→B crossing (and nowhere else).
 *   AgentLaunchpad— the per-agent factory, wired to both of the above.
 *
 * Per-agent contracts are NOT deployed here: the curve comes from `launchpad.launch()`, and the
 * AgentController from `launchpad.deployController()` once that agent's DobProtocol pool has
 * issued Product B.
 *
 * Set DOBX_ADDRESS to reuse an existing DOBX (the normal case after the first deploy) — minting
 * a second one would silently fragment every curve's quote token.
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address} on ${network.name}`);

  const treasury = process.env.PLATFORM_TREASURY || deployer.address;

  // ── DOBX: the quote token of every agent curve ────────────────────────────
  let dobx = process.env.DOBX_ADDRESS;
  if (!dobx) {
    const DOBX = await ethers.getContractFactory("DOBX");
    const token = await DOBX.deploy(treasury);
    await token.waitForDeployment();
    dobx = await token.getAddress();
    console.log(`DOBX: ${dobx}  (full supply → ${treasury})`);
  } else {
    console.log(`DOBX: ${dobx}  (existing)`);
  }

  // ── KYC registry: the gate at the crossing ────────────────────────────────
  const attestor = process.env.KYC_ATTESTOR || deployer.address;
  const Kyc = await ethers.getContractFactory("KycRegistry");
  const kyc = await Kyc.deploy(deployer.address, attestor);
  await kyc.waitForDeployment();
  const kycAddr = await kyc.getAddress();
  console.log(`KycRegistry: ${kycAddr}  (attestor ${attestor})`);

  // ── Controller factory (holds AgentController's creation code; see the contract) ──
  const CtrlFactory = await ethers.getContractFactory("AgentControllerFactory");
  const ctrlFactory = await CtrlFactory.deploy();
  await ctrlFactory.waitForDeployment();
  const ctrlFactoryAddr = await ctrlFactory.getAddress();
  console.log(`AgentControllerFactory: ${ctrlFactoryAddr}`);

  // ── Launchpad ─────────────────────────────────────────────────────────────
  const Launchpad = await ethers.getContractFactory("AgentLaunchpad");
  const launchpad = await Launchpad.deploy(deployer.address, dobx, treasury);
  await launchpad.waitForDeployment();
  const launchpadAddr = await launchpad.getAddress();
  await (await launchpad.setKycRegistry(kycAddr)).wait();
  await (await launchpad.setControllerFactory(ctrlFactoryAddr)).wait();

  console.log(`AgentLaunchpad: ${launchpadAddr}`);
  console.log(`  quoteToken:        ${dobx}`);
  console.log(`  platformTreasury:  ${treasury}`);
  console.log(`  kycRegistry:       ${kycAddr}`);
  console.log(`  controllerFactory: ${ctrlFactoryAddr}`);

  // Persist addresses so other tooling (the dobx BFF E2E) can pick them up.
  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, `${network.name}.json`),
    JSON.stringify({
      network: network.name,
      launchpad: launchpadAddr,
      dobx,
      kycRegistry: kycAddr,
      controllerFactory: ctrlFactoryAddr,
      quoteToken: dobx,
      platformTreasury: treasury,
    }, null, 2)
  );
  console.log(`Wrote deployments/${network.name}.json`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
