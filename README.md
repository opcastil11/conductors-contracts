# dobx-contracts

Smart contracts for **dobx.pro** — the RWA agent launchpad. This repo holds the **fair-launch
layer** (Nivel 2): a per-agent bonding curve that graduates into an AMM, in the style of
pump.fun / clawpump, adapted from DOBI's `DobiPump` and `DobiSwap` prototypes.

> Separate, public-facing repo (kept apart from the private `dobx-pro` app) so the contracts
> can be verified and audited independently. **Pre-audit — do not deploy to mainnet with real
> funds until audited.**

## What this is

Each agent (a real-world asset operated in DOBI, tokenized as a DobProtocol pool) can also be
**fair-launched**: its shares are sold on a bonding curve priced in USDC; once the raise hits
a target, the curve **graduates** — it seeds an AMM with the leftover shares + the USDC raised
and permanently locks the liquidity. From then on the share price is discovered on the AMM.

```
launch ──► AgentShareToken (fixed supply, minted into the curve)
           AgentBondingCurve  ── buy/sell in USDC, price rises with supply sold
                │  raised ≥ graduationRaise
                ▼
           _graduate(): deploy AgentAMM, seed (leftover shares + USDC), LOCK LP
                ▼
           AgentAMM (x*y=k, 0.3% fee)  ── continuous USDC market, price discovery
```

## Contracts

| Contract | Purpose |
|---|---|
| `AgentLaunchpad.sol` | Factory + registry. `launch(params)` deploys the token + curve, mints the supply into the curve, records the agent. Owner sets the quote token (USDC) & platform treasury. |
| `AgentShareToken.sol` | Fixed-supply ERC20 for one agent's shares. No mint after launch, no owner. The same balances DobProtocol reads to distribute the asset's real yield. |
| `AgentBondingCurve.sol` | Linear bonding curve priced **per whole share in USDC** (`price = basePrice + sold*slope`; cost = integral). Buy fee → platform; sell fee → pool. Graduates to the AMM at `graduationRaise`. |
| `AgentAMM.sol` | Constant-product AMM (`x*y=k`, 0.3% fee) for shares ↔ USDC. The post-graduation market. |
| `AgentTreasury.sol` | Per-agent treasury. **A is permanently locked** (no path out — retires repurchased A forever); **B strategic reserve** is owner-deployable (marketplace backstop / incentives); routes USDC fees. |
| `AgentBuyback.sol` | TWAP/batched buyer of **A** funded in USDC (real revenue + trading fees). Epoch spend cap + min interval + keeper gate; bought A → treasury (retired). |
| `AgentConverter.sol` | Convert **A→B, step 1**: sells A→USDC on the AMM, skims a 0.5–1% fee to the treasury, returns net USDC. **No oracle.** Step 2 (buy B) is the DobProtocol marketplace. |
| `mocks/MockUSDC.sol` | 6-decimal USDC stand-in for tests / testnets. |

## Tokenomics

The full value model — the two products (agent token **A** / distribution token **B**), the
mixed **TWAP buyback → treasury**, and the **USDC-mediated conversion A→B** (sell A for USDC,
buy B — no oracle) that bridges them — is specified in
**[docs/TOKENOMICS.md](docs/TOKENOMICS.md)**. Product A (curve + AMM), the treasury, buyback and
converter are implemented and tested here; B is DobProtocol's pool participation token (external).

## Design notes

- **Quote = USDC (6 dp).** Unlike the DobiPump/DobiSwap prototypes (which quoted in the 18-dp
  native coin), pricing is denominated **per whole share** so an 18-dp share token works
  against a 6-dp quote with exact integer arithmetic and no precision loss.
- **Liquidity is locked forever.** At graduation the LP is minted to the curve, which has no
  code path to withdraw it — so it can never be pulled (rug-proof by construction).
- **Fees.** Buy fee (bps, capped 5%) routes to the platform treasury; sell fee (bps) stays in
  the pool and lifts the floor for remaining holders. AMM swaps take the standard 0.3%.
- **Permissionless on-chain, gated off-chain.** Anyone *can* call `launch`, but in practice the
  dobx backend calls it for the operator whose DOBI asset is being tokenized.

## How it plugs into dobx / DOBI / DobProtocol

- **DOBI** operates the asset and produces the real revenue (x402 pay-per-use).
- **DobProtocol** distributes that revenue to holders of the share token (pull-based).
- **These contracts** provide the *market*: fair launch + continuous price for the same share
  token. Holding a share = a market position **and** a claim on the asset's cash flow.

## Develop

```bash
npm install
npm run compile
npm test            # 10 passing — full lifecycle incl. graduation & AMM swaps

cp .env.example .env  # set PRIVATE_KEY, QUOTE_TOKEN (USDC), PLATFORM_TREASURY
npm run deploy:baseSepolia
```

USDC on Base mainnet: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.

## Status

Nivel 2 reference implementation, **pre-audit**. Tests green (`npm test`, 13 passing).

**Internal audit fixes applied** (see the 3-front audit): graduation now seeds the AMM at
~the curve's terminal price (no ~2800× price cliff); the AMM uses **explicit reserves** (not
`balanceOf`) so donations can't move price / no first-depositor attack; `addLiquidity` pulls
only the matched pair; **deadlines** on all curve/AMM state changes; `launch()` is **gated**
(authorized launchers unless `publicLaunch`) and **Pausable**; inventory is donation-proof
(`curveSupply − sold`); leftover inventory → treasury; graduation config is validated.

**Still open before mainnet:** professional audit; **Foundry fuzz/invariant suite** (curve
solvency, k-monotonicity, graduation reachability, seed-price bounds); the graduating buy is
not partial-filled (a single oversized buy can overshoot `graduationRaise`); and the whole
Product-B / buyback / treasury / conversion layer in [docs/TOKENOMICS.md](docs/TOKENOMICS.md)
is still to build. Do not deploy to mainnet with real funds until audited.
