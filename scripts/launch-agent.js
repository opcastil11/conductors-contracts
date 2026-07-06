const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Launches ONE agent on an already-deployed AgentLaunchpad using the canonical params
 * (docs/DEPLOY.md): base $0.05, slope 1e-6 USDC/share, graduate at 200k → terminal $0.25.
 * Then mints MockUSDC to the deployer and does a small real buy on the curve to prove the
 * end-to-end loop on-chain. Appends the agent's {token, curve} to deployments/<network>.json.
 *
 * Env: AGENT_NAME, AGENT_SYMBOL, AGENT_SUPPLY (whole shares, default 1_000_000), BUY_SHARES
 * (whole shares to test-buy, default 100).
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  const depPath = path.join(__dirname, "..", "deployments", `${network.name}.json`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  console.log(`Launcher: ${deployer.address} on ${network.name}`);
  console.log(`Launchpad: ${dep.launchpad}  quote(USDC): ${dep.quoteToken}`);

  const launchpad = await ethers.getContractAt("AgentLaunchpad", dep.launchpad);
  const usdc = await ethers.getContractAt("MockUSDC", dep.quoteToken);

  const name = process.env.AGENT_NAME || "Maipu Solar Agent";
  const symbol = process.env.AGENT_SYMBOL || "MSOL";
  const supply = BigInt(process.env.AGENT_SUPPLY || "1000000"); // whole shares

  // Canonical curve params (USDC 6dp base units).
  const basePrice = 50_000n; // $0.05
  const slope = 1n; // 1e-6 USDC/share → terminal $0.25 at 200k sold
  const buyFeeBps = 100n; // 1%
  const sellFeeBps = 100n;
  const graduationRaise = 29_999_900_000n; // ≈ $30k net → graduate

  const params = {
    name,
    symbol,
    supply,
    basePrice,
    slope,
    buyFeeBps,
    sellFeeBps,
    graduationRaise,
  };

  console.log(`\nLaunching "${name}" (${symbol}), supply ${supply} shares…`);
  const tx = await launchpad.launch(params);
  const rcpt = await tx.wait();

  // Pull agentId/token/curve from the AgentLaunched event.
  const ev = rcpt.logs
    .map((l) => {
      try {
        return launchpad.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((e) => e && e.name === "AgentLaunched");
  const agentId = ev.args.agentId;
  const token = ev.args.token;
  const curve = ev.args.curve;
  console.log(`  agentId ${agentId}  token ${token}  curve ${curve}`);

  const bc = await ethers.getContractAt("AgentBondingCurve", curve);
  console.log(`  price now: ${await bc.getCurrentPrice()} base units  inventory: ${await bc.inventory()} shares`);

  // ── Test buy: mint USDC, approve, buy BUY_SHARES whole shares ──────────────
  const buyShares = BigInt(process.env.BUY_SHARES || "100");
  const cost = await bc.getBuyCost(buyShares);
  const fee = (cost * buyFeeBps) / 10_000n;
  const total = cost + fee;
  console.log(`\nTest buy ${buyShares} shares → cost ${cost} + fee ${fee} = ${total} base units ($${Number(total) / 1e6})`);

  await (await usdc.mint(deployer.address, total)).wait();
  await (await usdc.approve(curve, total)).wait();
  const deadline = Math.floor(Date.now() / 1000) + 600;
  const buyTx = await bc.buy(buyShares, total, deadline);
  await buyTx.wait();

  const shareToken = await ethers.getContractAt("AgentShareToken", token);
  const bal = await shareToken.balanceOf(deployer.address);
  console.log(`  bought. buyer A balance: ${ethers.formatUnits(bal, 18)} shares`);
  console.log(`  curve sold: ${await bc.sold()}  price now: ${await bc.getCurrentPrice()} base units  raised: ${await bc.raised()}`);

  // Persist agent info for the BFF chain-adapter.
  dep.agents = dep.agents || [];
  dep.agents.push({
    agentId: agentId.toString(),
    name,
    symbol,
    token,
    curve,
    supply: supply.toString(),
    basePrice: basePrice.toString(),
    slope: slope.toString(),
    graduationRaise: graduationRaise.toString(),
  });
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2));
  console.log(`\nWrote agent → deployments/${network.name}.json`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
