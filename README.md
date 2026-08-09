# dobx-contracts

Smart contracts for **dobx.pro** — the RWA agent launchpad. This repo holds the on-chain layer of
the **one-way A→B model**: a per-agent bonding curve quoted in **DOBX** that graduates into an
AMM, plus the controller that lets a holder cross, once and irreversibly, from the agent token
into a participation in the asset's future revenue.

> Separate, public-facing repo (kept apart from the private `dobx-pro` app) so the contracts
> can be verified and audited independently. **Pre-audit — do not deploy to mainnet with real
> funds until audited.**

## What this is

Every agent has **two** products, and they are not the same asset:

- **A — the agent token.** Perpetual, speculative, permissionless, quoted in DOBX. Fair-launched
  on a bonding curve that graduates into a locked-liquidity AMM. A pays no distributions; its
  link to the real asset is the **right to convert**.
- **B — participation in a DobProtocol future-revenue pool.** Finite and amortizing: it pays out
  a bounded total production and then ends. This is the instrument that actually receives the
  x402 revenue.

```
launch ──► AgentShareToken (A, fixed supply, minted into the curve)
           AgentBondingCurve  ── buy/sell in DOBX, price rises with supply sold
                │  raised ≥ graduationRaise
                ▼
           _graduate(): deploy AgentAMM, seed (leftover A + DOBX raised), LOCK LP
                ▼
           AgentAMM (x*y=k, 0.3% fee)  ── continuous DOBX market

                ── and, once the agent's DobProtocol pool exists ──

           AgentController ── convert(A) ──► burns A, releases the matching reserve
                              to capex, hands back B. One-way. Never B→A.
```

## Contracts

| Contract | Purpose |
|---|---|
| `DOBX.sol` | The platform token: fixed 1e9 supply minted to the treasury, no mint function, burnable. The quote token of **every** agent curve. |
| `AgentLaunchpad.sol` | Factory + registry. `launch(params)` deploys A + its curve and mints the supply in; `deployController(agentId, params)` attaches the A→B crossing once the agent's B pool exists. |
| `AgentShareToken.sol` | Fixed-supply ERC20 for one agent's A. No mint after launch, no owner. Burnable by the holder — which is how the curve retires converted A. |
| `AgentBondingCurve.sol` | Linear curve priced **per whole share in DOBX** (`price = basePrice + sold*slope`; cost = the integral). Graduates at `graduationRaise`. `redeemForConversion` — callable **only** by the bound controller — burns A and releases exactly the reserve that A's claim represented. |
| `AgentAMM.sol` | Constant-product AMM (`x*y=k`, 0.3% fee) for A ↔ DOBX. The post-graduation market. |
| `AgentController.sol` | The crossing. Immutable, ownerless. Snapshots the cap table at `activate()`, then `convert()` burns A, routes the released DOBX to the capex sink, and issues B at a fixed pro-rata ratio. Also custodies the creator's retained B behind a cliff + linear vest. |
| `AgentControllerFactory.sol` | Holds the controller's creation code so the launchpad fits under the 24 KB limit. No owner, no state, no funds. |
| `KycRegistry.sol` | The allowlist consulted at the crossing — and nowhere else. Trading A stays permissionless. |
| `mocks/MockUSDC.sol`, `mocks/MockParticipation.sol` | 6-dp USDC and a Product-B stand-in for tests. |

## Tokenomics

The value model — the two products, the one-way conversion, why releasing curve reserve against
burned A is solvency-preserving, the price floor `P_A ≥ P_B` and its decay, and the five coupled
creator parameters — is specified in **[docs/TOKENOMICS-V2.md](docs/TOKENOMICS-V2.md)** (vigente).
[docs/TOKENOMICS.md](docs/TOKENOMICS.md) is the superseded 2026-07-05 model (buyback + treasury +
USDC-mediated conversion) and is kept only for history.

## Design notes

- **Quote = DOBX (18 dp).** Pricing is denominated **per whole share**, so the integral stays
  exact integer arithmetic.
- **Conversion releases reserve, and that is safe.** Pre-graduation the released amount is the
  top-of-curve integral for the shares being retired — arithmetically identical to a sell, so
  every remaining holder can still exit. Post-graduation the reserve lives in the AMM, so the
  controller withdraws the *proportional* LP slice and burns the A leg, leaving DOBX-per-
  circulating-A untouched. The capex is not financed by the raise; it is financed by conversions.
- **Liquidity is locked forever.** The LP is minted to the curve, which has no withdrawal path
  other than the proportional shrink above.
- **The controller is immutable.** No owner, no proxy, no setter, no sweep. The accepted cost is
  that tokens sent to it by mistake are stuck forever.
- **Binding is one-shot.** `bindController` is launchpad-only and refuses a second call, so an
  agent's crossing can never be re-pointed after it is live.
- **Compliance sits at the crossing.** A is permissionless to trade; KYC is required only to
  convert into B.

## How it plugs into dobx / DOBI / DobProtocol

- **DOBI** operates the asset and produces the real revenue (x402 pay-per-use).
- **DobProtocol** runs the future-revenue pool and distributes 100% of what lands there to B
  holders, with every cut expressed inside the cap table.
- **These contracts** provide the attention market (A), and the one-way door from it into B.

## Develop

```bash
npm install
npm run compile
npm test            # 42 passing — lifecycle, graduation, AMM, and the full A→B crossing

cp .env.example .env  # set PRIVATE_KEY, PLATFORM_TREASURY (and DOBX_ADDRESS after the first deploy)
npm run deploy:baseSepolia
```

## Status

Reference implementation of TOKENOMICS-V2, **pre-audit**. Tests green (`npm test`, 42 passing).

**Internal audit fixes applied** (see the 3-front audit): graduation seeds the AMM at ~the
curve's terminal price (no price cliff); the AMM uses **explicit reserves** (not `balanceOf`) so
donations can't move price / no first-depositor attack; `addLiquidity` pulls only the matched
pair; **deadlines** on all curve/AMM state changes; `launch()` is **gated** and **Pausable**;
inventory is donation-proof; leftover inventory → treasury; graduation config is validated.

**Still open before mainnet:** professional audit; **Foundry fuzz/invariant suite** (curve
solvency across conversions, k-monotonicity, graduation reachability, seed-price bounds); the
graduating buy is not partial-filled (a single oversized buy can overshoot `graduationRaise`);
and the open items in [docs/TOKENOMICS-V2.md](docs/TOKENOMICS-V2.md) §7.3 — chiefly §4.2, that
released reserve is DOBX while capex is fiat. Do not deploy to mainnet with real funds until
audited.
