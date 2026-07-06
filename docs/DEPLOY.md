# dobx-contracts — Deployment Runbook

Status of the suite (verified 2026-07-06): **41 Hardhat + 11 Foundry tests passing**, git-clean,
`deploy.js` exercised locally (`deployments/localhost.json`, `deployments/hardhat.json`). The only
thing standing between here and a live **Base Sepolia** deployment is a **funded deployer key** — an
owner-supplied credential. This file is the single owner step + the canonical launch params.

---

## 1. The one owner step — deploy to Base Sepolia

The repo has **no `.env`** on purpose (no key committed). To deploy you must supply a funded key.

```bash
cd dobx-contracts

# 1. Fund a throwaway deployer wallet with Base Sepolia ETH (faucet: https://www.alchemy.com/faucets/base-sepolia).

# 2. Create .env (gitignored — NEVER commit it). Minimum:
#    PRIVATE_KEY=0x<funded deployer key>
#    USE_MOCK_USDC=1                # fresh testnet has no canonical USDC → deploy a MockUSDC
#    BASE_SEPOLIA_RPC_URL=https://sepolia.base.org   # optional; this is the default
#    BASESCAN_API_KEY=<optional, for verification>
cp .env.example .env && $EDITOR .env

# 3. Deploy launchpad + tokenomics factory (+ MockUSDC on testnet).
npm run deploy:baseSepolia
#   → writes deployments/baseSepolia.json { launchpad, tokenomicsFactory, quoteToken, platformTreasury }

# 4. (mainnet, later) real USDC is 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 → drop USE_MOCK_USDC,
#    set QUOTE_TOKEN to it, and: npm run deploy:base
```

`deployments/baseSepolia.json` is the handoff artifact — the dobx BFF chain-adapter reads the
launchpad + factory + quoteToken addresses from it.

**Security:** the deployer key is the launchpad `owner` and the sole `authorizedLauncher` until it
authorizes the dobx backend signer (`setAuthorizedLauncher(backendSigner, true)`) or flips
`setPublicLaunch(true)`. Keep it offline; rotate before mainnet. Do NOT paste it into chat or commit
`.env`.

---

## 2. Canonical launch params (must match the BFF market)

The bonding curve prices per **whole share** in **USDC base units (6 dp)**, and the slope is an
**integer**: `price(sold) = basePrice + sold*slope`, cost = the exact integral. That integer
constraint pins the demo economics. The dobx BFF (`apps/api/.../market.service.js`) mirrors these:

| Param | Value | On-chain (`LaunchParams`) |
|-------|-------|---------------------------|
| Base price | **$0.05** | `basePrice = 50_000` (0.05 × 1e6) |
| Slope | **1e-6 USDC/share** | `slope = 1` (smallest integer step) |
| Terminal price | **$0.25** | reached at `sold = 200_000` |
| Graduation supply | **200,000 shares** | — |
| Graduation raise | **≈ $29,999.90** | `graduationRaise = 29_999_900_000` base units |
| Total share supply | per-agent (e.g. 1,000,000) | `supply` (whole shares, minted ×1e18) |
| Convert fee | **0.75%** → treasury | `AgentConverter` fee bps = 75 (TOKENOMICS §5 band 0.5–1%) |

> ⚠️ **Why not 400k?** A $0.05→$0.25 span over **400k** shares needs slope = 0.5 base units/share,
> which the integer curve can't represent. **200k** is the largest graduation supply that keeps the
> terminal at exactly $0.25 with an integer slope. The BFF's `GRAD_SUPPLY` was moved 400k→200k to
> match (2026-07-06). If a different terminal is acceptable, slope=1 with grad=400k gives terminal $0.45.

Example `launch(LaunchParams)` for a 1,000,000-share agent:
```
name, symbol,
supply           = 1_000_000,
basePrice        = 50_000,        // $0.05
slope            = 1,             // 1e-6 USDC/share
buyFeeBps        = 100,           // 1% (≤ maxBuyFeeBps 500)
sellFeeBps       = 100,           // 1%
graduationRaise  = 29_999_900_000 // ≈ $30k net raised → curve graduates into the AMM
```
`_validateGraduation` requires `graduationRaise < fullIntegral(supply)`, satisfied here.

---

## 3. Post-deploy wiring (BFF chain-adapter — next phase, no key needed to build)

Once `deployments/baseSepolia.json` exists, the BFF gains a chain-mode market adapter that mirrors
the current `marketService` interface (`state/buy/sell/convert`) but reads/writes the real curve/AMM
via ethers, and the web app moves buys to a **browser-wallet signing flow** (approve USDC → `curve.buy`),
same pattern as the DobProtocol Stellar flow. This can be built and tested against a **local hardhat
node** before the testnet key exists — flip a `MARKET_MODE=chain` flag when addresses are live.

Build order to go live on-chain:
1. ✅ Contracts complete + tested (41+11 green).
2. ⛔ Deploy to Base Sepolia — **needs funded deployer key (owner)**. ← the only blocker.
3. BFF chain-adapter behind `MARKET_MODE` flag (buildable now vs a local node).
4. Web signing flow for buy/sell/convert (approve + tx, wallet-signed).
5. Revenue router split (b%/d%, bounded 10–50%) wiring the buyback + DobProtocol distribution.
