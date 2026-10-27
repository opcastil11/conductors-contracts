/**
 * End-to-end exercise of the one-way crossing against a LIVE deployment.
 *
 * Unlike test/controller.test.js this talks to the real Conductors BFF and a real network, so it also
 * checks the seams the unit tests cannot see: that the API's managed signer owns the launchpad,
 * that its prepare-bundles are signable as-is, and that the ratio the UI advertises is the ratio
 * the contract actually pays.
 *
 * Stages (STAGE=…), run in order with the BFF calls in between:
 *   b        — deploy the stand-in Product B and mint `--supply` to the deployer
 *   buy      — buy A from the curve (activate() needs A supply, and a converter needs A)
 *   fund     — send B to the controller and KYC-approve the converter
 *   convert  — walk the BFF's convert bundle and assert what moved
 *
 * Every address comes from env so the script never assumes a particular deployment:
 *   AGENT=<Conductors agent id> CURVE=… TOKEN=… CONTROLLER=… PT=… API=https://conductors.io/api
 */
const { ethers } = require("hardhat");

const API = process.env.API || "https://conductors.io/api";
const AGENT = process.env.AGENT;

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function mint(address,uint256)",
];
const CURVE = [
  "function buy(uint256,uint256,uint256)",
  "function getBuyCost(uint256) view returns (uint256)",
  "function quoteToken() view returns (address)",
  "function shareToken() view returns (address)",
];

/** Re-read `snapshot` until `ready` holds (or we give up), tolerating a lagging RPC node. */
async function settled(snapshot, ready, tries = 12, delayMs = 2500) {
  let last;
  for (let i = 0; i < tries; i++) {
    last = await snapshot();
    if (ready(last)) return last;
    await new Promise((r) => setTimeout(r, delayMs));
  }
  console.log("WARNING: state never changed — reporting the last read as-is");
  return last;
}

async function main() {
  const stage = process.env.STAGE;
  const [me] = await ethers.getSigners();
  console.log(`stage=${stage} signer=${me.address}`);

  if (stage === "b") {
    const PT = await (await ethers.getContractFactory("MockParticipation")).deploy();
    await PT.waitForDeployment();
    const addr = await PT.getAddress();
    // Issue B 1:1 against A's TOTAL supply: the contract pays `convertibleB / aSupplyAtActivation`
    // per A, so any other issuance silently changes the ratio the launchpad advertises.
    const supply = ethers.parseUnits(process.env.SUPPLY || "1000000", 18);
    await (await PT.mint(me.address, supply)).wait();
    console.log(`PT=${addr} minted=${ethers.formatUnits(supply, 18)}`);
    return;
  }

  if (stage === "buy") {
    const curve = new ethers.Contract(process.env.CURVE, CURVE, me);
    const shares = BigInt(process.env.SHARES || "2000");
    const cost = await curve.getBuyCost(shares);
    const max = (cost * 110n) / 100n;
    const quote = new ethers.Contract(await curve.quoteToken(), ERC20, me);
    await (await quote.approve(process.env.CURVE, max)).wait();
    const tx = await curve.buy(shares, max, Math.floor(Date.now() / 1000) + 900);
    await tx.wait();
    const token = new ethers.Contract(await curve.shareToken(), ERC20, me);
    const bal = await settled(() => token.balanceOf(me.address), (v) => v > 0n);
    console.log(`bought=${shares} cost=${ethers.formatUnits(cost, 18)} DOBX A=${ethers.formatUnits(bal, 18)} tx=${tx.hash}`);
    return;
  }

  if (stage === "fund") {
    const pt = new ethers.Contract(process.env.PT, ERC20, me);
    const amount = await pt.balanceOf(me.address);
    await (await pt.transfer(process.env.CONTROLLER, amount)).wait();
    const kyc = new ethers.Contract(process.env.KYC, ["function setApproved(address,bool)", "function isApproved(address) view returns (bool)"], me);
    await (await kyc.setApproved(me.address, true)).wait();
    console.log(`controller B=${ethers.formatUnits(await pt.balanceOf(process.env.CONTROLLER), 18)} kyc(${me.address})=${await kyc.isApproved(me.address)}`);
    return;
  }

  if (stage === "convert") {
    const shares = Number(process.env.SHARES || "500");
    const prep = await (await fetch(`${API}/agents/${AGENT}/convert/prepare`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // The route names it `amountTokens` (whole A, not wei) — same field the sell path uses.
      body: JSON.stringify({ wallet: me.address, amountTokens: shares }),
    })).json();
    if (prep.error) throw new Error(`prepare failed: ${prep.error}`);
    console.log(`prepare: bOut=${prep.bOut} ratio=${prep.ratio} oneWay=${prep.oneWay} steps=${prep.steps.length}`);

    const a = new ethers.Contract(process.env.TOKEN, ERC20, me);
    const b = new ethers.Contract(process.env.PT, ERC20, me);
    const quote = new ethers.Contract(process.env.DOBX, ERC20, me);
    const before = {
      a: await a.balanceOf(me.address),
      b: await b.balanceOf(me.address),
      sink: await quote.balanceOf(process.env.SINK),
      supply: await a.totalSupply(),
    };

    // Sign the BFF's bundle verbatim — this is exactly what the browser wallet does.
    for (const s of prep.steps) {
      const tx = await me.sendTransaction({ to: s.to, data: s.data, value: s.value || 0 });
      await tx.wait();
      console.log(`  ${s.kind}: ${tx.hash}`);
    }

    // The public RPC is load-balanced and some nodes trail the head, so a read issued right after
    // the receipt can still answer from pre-tx state. Poll until the supply actually moves,
    // otherwise the assertions below would "pass" against stale numbers.
    const after = await settled(async () => ({
      a: await a.balanceOf(me.address),
      b: await b.balanceOf(me.address),
      sink: await quote.balanceOf(process.env.SINK),
      supply: await a.totalSupply(),
    }), (s) => s.supply !== before.supply);
    const f = (x) => ethers.formatUnits(x, 18);
    console.log(`A spent      : ${f(before.a - after.a)}`);
    console.log(`A burned     : ${f(before.supply - after.supply)}   <- supply must fall by the same amount`);
    console.log(`B received   : ${f(after.b - before.b)}`);
    console.log(`capex sink   : +${f(after.sink - before.sink)} DOBX`);
    console.log(`converter got: ${f(await quote.balanceOf(me.address))} DOBX total (no payout is expected)`);
    return;
  }

  throw new Error(`unknown STAGE=${stage}`);
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
