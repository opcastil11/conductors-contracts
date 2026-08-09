/**
 * End-to-end proof that the grace period actually SHUTS the crossing on a live network.
 *
 * Both earlier live runs used graceDays 0, so the door was open the moment it existed and the
 * grace clock was never exercised against real block timestamps. Grace is not a lockup detail: it
 * is what leaves A alone as an attention market during the window when the pool is paying nothing,
 * and "the pool has not started distributing, so there is nothing to cross into" is only true if
 * `convert()` genuinely reverts.
 *
 * The script launches its own agent, attaches a controller with a SHORT grace (default 180s),
 * activates, asserts the revert, waits out the clock on chain time, and asserts the same call then
 * succeeds — so both halves are observed on the same controller.
 *
 *   npx hardhat run scripts/e2e-grace.js --network baseSepolia
 *
 * Env: GRACE_SECONDS, SHARES, LAUNCHPAD (defaults to deployments/baseSepolia.json).
 */
const { ethers } = require("hardhat");
const deployment = require("../deployments/baseSepolia.json");

const CURVE = [
  "function buy(uint256,uint256,uint256)",
  "function getBuyCost(uint256) view returns (uint256)",
  "function quoteToken() view returns (address)",
  "function shareToken() view returns (address)",
];
const CONTROLLER = [
  "function activate()",
  "function convert(uint256,uint256) returns (uint256)",
  "function activated() view returns (bool)",
  "function graceEnd() view returns (uint64)",
  "function convertibleB() view returns (uint256)",
  "function aSupplyAtActivation() view returns (uint256)",
];
const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function mint(address,uint256)",
];

const f = (v) => ethers.formatUnits(v, 18);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function settled(read, ready, tries = 16, delayMs = 2500) {
  let last;
  for (let i = 0; i < tries; i++) {
    last = await read();
    if (ready(last)) return last;
    await sleep(delayMs);
  }
  console.log("WARNING: state never changed — reporting the last read as-is");
  return last;
}

async function main() {
  const [me] = await ethers.getSigners();
  const graceSeconds = Number(process.env.GRACE_SECONDS || 180);
  const shares = BigInt(process.env.SHARES || "200");
  const launchpad = await ethers.getContractAt("AgentLaunchpad", process.env.LAUNCHPAD || deployment.launchpad, me);
  console.log(`signer=${me.address} grace=${graceSeconds}s`);

  // ── Launch a small agent and take some A ───────────────────────────────────
  const rc = await (await launchpad.launch({
    name: `Grace E2E ${Date.now()}`,
    symbol: "GRACE",
    supply: 1000n,
    basePrice: ethers.parseUnits("0.05", 18),
    slope: ethers.parseUnits("0.0001", 18),
    buyFeeBps: 100,
    sellFeeBps: 100,
    graduationRaise: ethers.parseUnits("90", 18), // out of reach for this run — grace, not graduation
  })).wait();
  const ev = rc.logs
    .map((l) => { try { return launchpad.interface.parseLog(l); } catch { return null; } })
    .find((e) => e?.name === "AgentLaunched");
  const { agentId, token, curve: curveAddr } = ev.args;
  console.log(`launched agentId=${agentId} token=${token} curve=${curveAddr}`);
  await settled(() => ethers.provider.getCode(curveAddr), (c) => c && c !== "0x");

  const curve = new ethers.Contract(curveAddr, CURVE, me);
  const quote = new ethers.Contract(await curve.quoteToken(), ERC20, me);
  const cost = await curve.getBuyCost(shares);
  await (await quote.approve(curveAddr, (cost * 110n) / 100n)).wait();
  await (await curve.buy(shares, (cost * 110n) / 100n, Math.floor(Date.now() / 1000) + 900)).wait();
  console.log(`bought ${shares} A for ${f(cost)} DOBX`);

  // ── Attach the crossing with a short grace ─────────────────────────────────
  const PT = await (await ethers.getContractFactory("MockParticipation")).deploy();
  await PT.waitForDeployment();
  const ptAddr = await PT.getAddress();
  // B issued 1:1 against A's total supply, so the paid ratio equals the advertised (1 - retained).
  await (await PT.mint(me.address, ethers.parseUnits("1000", 18))).wait();

  const dep = await (await launchpad.deployController(agentId, {
    participationToken: ptAddr,
    capexSink: me.address,
    retainedBps: 3000,
    graceSeconds,
    cliffSeconds: graceSeconds,
    vestSeconds: 60,
  })).wait();
  const cev = dep.logs
    .map((l) => { try { return launchpad.interface.parseLog(l); } catch { return null; } })
    .find((e) => e?.name === "ControllerDeployed");
  const controllerAddr = cev.args.controller;
  console.log(`controller=${controllerAddr} PT=${ptAddr}`);
  await settled(() => ethers.provider.getCode(controllerAddr), (c) => c && c !== "0x");

  const controller = new ethers.Contract(controllerAddr, CONTROLLER, me);
  await (await PT.transfer(controllerAddr, ethers.parseUnits("1000", 18))).wait();
  await (await controller.activate()).wait();
  const graceEnd = Number(await settled(() => controller.graceEnd(), (g) => Number(g) > 0));
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  console.log(`activated · graceEnd=${graceEnd} (chain now=${now}, ${graceEnd - now}s to go)`);

  // ── Half 1: the door is shut ───────────────────────────────────────────────
  const a = new ethers.Contract(token, ERC20, me);
  await (await a.approve(controllerAddr, shares * 10n ** 18n)).wait();
  let reverted = null;
  try {
    await controller.convert.staticCall(1n, 0n);
  } catch (e) {
    reverted = e.shortMessage || e.reason || e.message;
  }
  console.log(`convert during grace → ${reverted ?? "NO REVERT"}`);
  if (!reverted || !/grace/i.test(reverted)) throw new Error(`expected a "grace period" revert, got: ${reverted}`);

  // Compliance sits after the grace check in `convert()`, so half 1 revert-tests grace whether or
  // not this address is cleared. Half 2 needs the mirror written, or it would revert on KYC and
  // look like grace never expired.
  const kyc = new ethers.Contract(deployment.kycRegistry, [
    "function isApproved(address) view returns (bool)",
    "function setApproved(address,bool)",
  ], me);
  if (!(await kyc.isApproved(me.address))) {
    await (await kyc.setApproved(me.address, true)).wait();
    console.log(`kyc mirror written for ${me.address}`);
  }

  // ── Half 2: same call, after the clock ─────────────────────────────────────
  const waitFor = Math.max(0, graceEnd - now) + 15; // +15s so the next block's timestamp is past it
  console.log(`waiting ${waitFor}s for the grace clock…`);
  await sleep(waitFor * 1000);

  const tx = await controller.convert(1n, 0n);
  await tx.wait();
  const bBal = await settled(() => PT.balanceOf(me.address), (v) => v > 0n);
  console.log(`convert after grace → OK · B received=${f(bBal)} tx=${tx.hash}`);
  console.log("OK — grace shut the crossing and then opened it, on real block timestamps");
}

main().catch((e) => { console.error(e); process.exit(1); });
