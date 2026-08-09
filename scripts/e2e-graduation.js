/**
 * End-to-end graduation against a LIVE network: buy up a curve until it crosses
 * `graduationRaise`, then check what the AMM was actually seeded with.
 *
 * The claim being tested is the one in AgentBondingCurve's header — "no graduation price cliff".
 * A curve that graduates into an AMM priced anywhere other than ~its terminal price hands the
 * first post-graduation trader a free gap, so the assertion that matters is price continuity, not
 * merely that `graduated` flipped.
 *
 * It launches its OWN small agent (supply 1000, graduation at 30 DOBX) instead of driving a real
 * one: the production curve graduates at ~30,000 DOBX, which is a lot of treasury to spend to
 * observe an arithmetic property that does not depend on scale.
 *
 *   npx hardhat run scripts/e2e-graduation.js --network baseSepolia
 *
 * Env: LAUNCHPAD (defaults to deployments/baseSepolia.json), SUPPLY, GRAD_RAISE, SHARES.
 */
const { ethers } = require("hardhat");
const deployment = require("../deployments/baseSepolia.json");

const CURVE = [
  "function buy(uint256,uint256,uint256)",
  "function getBuyCost(uint256) view returns (uint256)",
  "function getCurrentPrice() view returns (uint256)",
  "function quoteToken() view returns (address)",
  "function shareToken() view returns (address)",
  "function graduated() view returns (bool)",
  "function amm() view returns (address)",
  "function raised() view returns (uint256)",
  "function sold() view returns (uint256)",
];
const AMM = [
  "function shareReserve() view returns (uint256)",
  "function quoteReserve() view returns (uint256)",
  "function quoteForShare(uint256) view returns (uint256)",
];
const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

const f = (v) => ethers.formatUnits(v, 18);

/** Re-read until `ready` holds — the public RPC lags a block or two behind a mined tx. */
async function settled(read, ready, tries = 12, delayMs = 2500) {
  let last;
  for (let i = 0; i < tries; i++) {
    last = await read();
    if (ready(last)) return last;
    await new Promise((r) => setTimeout(r, delayMs));
  }
  console.log("WARNING: state never changed — reporting the last read as-is");
  return last;
}

async function main() {
  const [me] = await ethers.getSigners();
  const launchpad = await ethers.getContractAt("AgentLaunchpad", process.env.LAUNCHPAD || deployment.launchpad, me);
  console.log(`signer=${me.address} launchpad=${await launchpad.getAddress()}`);

  // supply 1000 · base 0.05 · slope 1e-4 ⇒ full integral ≈ 99.95 DOBX, so a 30 DOBX graduation is
  // reachable at ~430 shares. `graduationRaise < fullIntegral` is enforced on-chain.
  const supply = BigInt(process.env.SUPPLY || "1000");
  const basePrice = ethers.parseUnits("0.05", 18);
  const slope = ethers.parseUnits("0.0001", 18);
  const gradRaise = ethers.parseUnits(process.env.GRAD_RAISE || "30", 18);

  const tx = await launchpad.launch({
    name: `Graduation E2E ${Date.now()}`,
    symbol: "GRAD",
    supply,
    basePrice,
    slope,
    buyFeeBps: 100,
    sellFeeBps: 100,
    graduationRaise: gradRaise,
  });
  const rc = await tx.wait();
  const ev = rc.logs
    .map((l) => { try { return launchpad.interface.parseLog(l); } catch { return null; } })
    .find((e) => e?.name === "AgentLaunched");
  const curveAddr = ev.args.curve;
  console.log(`launched agentId=${ev.args.agentId} token=${ev.args.token} curve=${curveAddr}`);

  // The launch tx is mined, but a public RPC can still answer `getCode` for the fresh curve with
  // `0x` — every call against it then fails to decode. Wait for the node to see the code.
  await settled(() => ethers.provider.getCode(curveAddr), (c) => c && c !== "0x");

  const curve = new ethers.Contract(curveAddr, CURVE, me);
  const quote = new ethers.Contract(await curve.quoteToken(), ERC20, me);

  const shares = BigInt(process.env.SHARES || "430");
  const cost = await curve.getBuyCost(shares);
  const max = (cost * 110n) / 100n;
  console.log(`buying ${shares} shares · cost=${f(cost)} DOBX (balance=${f(await quote.balanceOf(me.address))})`);
  await (await quote.approve(curveAddr, max)).wait();
  const buyTx = await curve.buy(shares, max, Math.floor(Date.now() / 1000) + 900);
  await buyTx.wait();

  const graduated = await settled(() => curve.graduated(), (g) => g === true);
  const ammAddr = await curve.amm();
  console.log(`graduated=${graduated} amm=${ammAddr} tx=${buyTx.hash}`);
  if (!graduated) throw new Error("curve did not graduate — raise the share count");

  const amm = new ethers.Contract(ammAddr, AMM, me);
  const [shareReserve, quoteReserve, terminal] = await Promise.all([
    amm.shareReserve(), amm.quoteReserve(), curve.getCurrentPrice(),
  ]);
  const seedPrice = (quoteReserve * 10n ** 18n) / shareReserve;
  const drift = (Number(seedPrice - terminal) / Number(terminal)) * 100;

  // The seed count is `raised / terminalPrice` in WHOLE shares, so the pool price can only differ
  // from the curve's last price by that integer truncation — a fraction of one share's worth.
  console.log(`AMM seeded: ${f(shareReserve)} A + ${f(quoteReserve)} DOBX`);
  console.log(`price at graduation: curve=${f(terminal)} amm=${f(seedPrice)} DOBX (drift ${drift.toFixed(3)}%)`);
  console.log(`1 A now sells into the AMM for ${f(await amm.quoteForShare(10n ** 18n))} DOBX`);
  if (Math.abs(drift) > 1) throw new Error(`price cliff at graduation: ${drift.toFixed(3)}%`);

  // Unsold inventory goes to the platform treasury. On this deployment the treasury IS the
  // deployer, so its balance also contains the A just bought — report the two apart.
  const treasuryA = await new ethers.Contract(await curve.shareToken(), ERC20, me).balanceOf(deployment.platformTreasury);
  const leftover = treasuryA - (deployment.platformTreasury === me.address ? shares * 10n ** 18n : 0n);
  console.log(`leftover A to treasury: ${f(leftover)} (of ${supply} minted: ${shares} sold, ${f(shareReserve)} seeded)`);
  console.log("OK — graduated with no price cliff");
}

main().catch((e) => { console.error(e); process.exit(1); });
