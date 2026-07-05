# dobx.pro — Tokenomics & Mechanism Design

> Canonical spec for how value flows through a dobx agent. Read this before touching the
> contracts.
>
> **Status: parameters signed off by the owner 2026-07-05, pre-audit.** The conversion is now a
> **USDC-mediated swap with no NAV oracle** (see §5) — this supersedes the earlier oracle-anchored
> `AgentConversion`, which has been removed. Contract set as of this revision: Product A (curve →
> AMM), `AgentConverter` (A→USDC + fee), `AgentBuyback` (TWAP), `AgentTreasury` (A-sink + B
> reserve). Product B is the DobProtocol pool participation token (no new contract).

---

## 1. Mental model — a convertible: growth ⇄ income

Each agent has **two tokens**, sold as **two distinct products**, linked by a one-way
**conversion**:

```
   PRODUCT A — Agent Token (growth)              PRODUCT B — Distribution Token (income)
   speculative • bonding curve → AMM             yield-bearing • DobProtocol pool
   "bet on the agent's success"                  "collect the asset's real cash flow"
        │                                                 ▲
        │   ── CONVERT: sell A → USDC → buy B ────────────┘
        │      (one-way in practice; USDC-priced, NO oracle; small fee → treasury)
        │
   BUYBACK ◄── funded by a MIX: real x402 asset revenue + curve/AMM trading fees
        │       (TWAP / batched buys of A)
        └────► TREASURY  (retires repurchased A forever; holds the strategic B reserve)
```

In TradFi terms this is a **convertible instrument**: **A** behaves like growth equity
(price tracks belief in the agent), **B** behaves like an income share (a pro-rata claim on
the asset's real cash flow). A holder can **convert A → B** to move from speculative upside
to steady yield. The conversion is what tethers A's price to real value — without it, A is
pure momentum; with it, A has a **fundamental floor** equal to the B (and therefore the real
yield) you could obtain by converting.

You can enter either product independently:
- **Buy A** on the bonding curve / AMM — speculative, liquid, no direct yield.
- **Buy B** (or convert A→B) — a claim on the asset's distributed revenue.

---

## 2. The two tokens

### Product A — Agent Token
- **What:** fixed-supply ERC-20 sold on a per-agent bonding curve that graduates into an AMM
  (already implemented: `AgentShareToken`, `AgentBondingCurve`, `AgentAMM`).
- **Value accrual:** price on the curve/AMM **plus** buyback pressure (§4) **plus** the
  arbitrage floor from A→B convertibility (§5).
- **Does NOT receive** pro-rata revenue distributions directly. (This is why the auditors'
  "buyers get no yield" finding is **by design, not a bug** — A's link to yield is the
  convertibility, not a distribution.)

### Product B — Distribution Token
- **What:** the **DobProtocol participation token** of the agent's pool — the token the
  pull-based distributor pays real revenue to. **Fixed supply** (it represents fractional
  ownership of the asset's cash flow, like shares).
- **Value accrual:** receives the agent's real x402 revenue pro-rata, pull-based (claim).
- **Yield per token = R / B_supply** where `R` is net distributable revenue per period.
  Because supply is **fixed**, per-token yield is stable (see §5 for why conversion must not
  inflate B_supply).

> **Chain (signed off):** A and B must live on the **same chain per agent** (the convert flow
> routes A→USDC→B on one chain). DobProtocol supports Stellar + Base; the curve/AMM/converter/
> buyback contracts are EVM. → the **creator picks Base or Stellar**; the EVM contract set here
> targets Base (a Soroban port is required for Stellar-chosen agents).

---

## 3. Value flows (per period)

```
 real-world usage ──x402──► agent revenue R_gross
                               │
                               ├─ operating costs / operator split      →  operator
                               ├─ platform + DobProtocol fees           →  protocol
                               ├─ BUYBACK allocation (⚙️ b%)            →  buys A → treasury
                               └─ DISTRIBUTION allocation (⚙️ d%)       →  B holders (pull-based)

 curve/AMM trading ──fees──► buyback allocation (⚙️)                    →  buys A → treasury
```

The **split of real revenue** between *buyback* (benefits A) and *distribution* (benefits B)
is the core tokenomics knob and the point of tension between the two investor classes. It is
**configurable per agent but bounded, fixed and disclosed at launch** (not operator-adjustable
after the fact).

> **Revenue split (signed off):** `R_net = R_gross − costs − fees`, then `R_net = b%·buyback +
> d%·distribution`, with **b (buyback) constrained to 10–50%** → distribution always ≥ 50%. The
> bound keeps the income product the anchor and prevents a creator from starving B holders. The
> exact split is the creator's choice within that band and is disclosed on the agent page.

---

## 4. Buyback → Treasury

- **Funding (mix, confirmed):** part **real x402 revenue** (the differentiated, non-circular
  source) + part **curve/AMM trading fees** (circular, clawpump-style — disclose the split so
  the "real" fraction is legible; the honest thesis rests on the real fraction).
- **Action:** the buyback market-buys **A** and sends it to the **treasury**.
- **Destination (confirmed): treasury** — repurchased A accumulates in a treasury rather than
  being burned. The treasury is not idle: it is the **backstop for conversion** (§5) and a war
  chest (incentives, LP support, reserves).

**Risks to handle (from the audit):**
- **MEV:** an on-chain buyback is front-runnable. Execute via **TWAP / batched buys / a
  private mempool**, never a single naive market buy. ⚙️ pick an execution strategy.
- **Circularity honesty:** the trading-fee portion is self-referential value; only the x402
  portion is real. Report both.
- **Treasury governance (confirmed):** treasury **A is permanently non-sellable** — the
  contract has no path to transfer A out, so repurchased A is retired forever and can never be
  dumped on holders. The strategic **B reserve is owner-deployable** (list on the marketplace to
  backstop the convert flow, or fund incentives); deploying B makes it circulate and dilutes
  per-token yield, so it is a **disclosed governance lever**, not a locked balance.

---

## 5. Conversion A → B (the bridge) — USDC-mediated, no oracle

This is the bridge between the two products. An earlier draft made it a bespoke primitive with
a NAV oracle and a minted/reserve-drawn B; that was **rejected in favor of something simpler and
safer**. The insight: because DobProtocol pools **distribute and trade in USDC**, "convert A to
B" is just **sell A for USDC, then buy B with USDC**. No oracle, no special rate, no new price
to trust or manipulate — each side is priced by its own market.

### Why the old peg/oracle design was dropped
- A **fixed mint-on-convert peg** grows `B_supply` and dilutes `yield_per_B = R / B_supply`
  toward zero — it collapses the income product.
- A **NAV-oracle rate** removes the dilution but adds a trusted/manipulable price feed and a
  bounded reserve that halts conversions — complexity and a new attack surface.
- **USDC routing sidesteps both:** you get exactly what the two open markets say A and B are
  worth, and B's fixed supply is untouched because you **buy existing B**, you don't mint it.

### The mechanism (signed off)
1. **Two hops through USDC.** `A ──sell on AgentAMM──► USDC ──buy on DobProtocol marketplace──► B`.
   `price_B` is simply what B costs in USDC on its marketplace; `price_A` is the AMM price.
2. **On-chain half = `AgentConverter`.** It does the atomic, trust-minimized part: pull A, sell
   it on the AMM, **skim a small convert fee (0.5–1%) to the treasury**, return net USDC to the
   user. Selling A directly on the AMM is always possible and fee-free — the fee is the price of
   the one-click "convert" product and it funds the treasury.
3. **Off-chain half = step 2.** The user (or the dApp for them) buys B on the DobProtocol
   marketplace with that USDC. The marketplace is **listing-based, not an AMM**, so the two hops
   **can't be a single atomic tx** — convert is a **2-step flow**.
4. **Liquidity backstop.** So B is always buyable, the **treasury lists part of its strategic B
   reserve** on the marketplace (see §4). If peer listings are thin, the protocol's reserve is
   the counterparty.
5. **One-way in practice.** There's a symmetric B→A path (sell B, buy A) but the product only
   surfaces A→B; the design nudges holders from speculation toward income, not back.

### Result
- **A holders** can always exit into income at the real market rate of B — a genuine
  yield-linked exit, priced by markets not by a trusted oracle.
- **B holders** are **not diluted by conversion**: no B is minted; convert buys existing B. The
  only thing that increases circulating B is the treasury *choosing* to deploy its reserve — a
  disclosed governance action, not an automatic mint.
- **No oracle in the conversion path** → one fewer trusted component and manipulation surface.
- **The two products stay coherent:** the same real revenue funds (a) the buyback that supports
  A and (b) the distribution that pays B — split by the disclosed, bounded `b%/d%`.

> ⚙️ **Open parameters:** exact convert fee within 0.5–1%, size of the treasury B reserve
> actually listed as backstop vs held, whether to offer an aggregator that bundles the 2 steps
> in the UI.

---

## 6. The revenue-attestation dependency (unavoidable)

The **revenue split** (§3) — and any NAV/yield figure shown in the UI — depends on the asset's
**real reported revenue**. (Note the conversion no longer needs a price oracle at all, §5 — this
gap is now only about *how much revenue is real*, not about pricing the conversion.) Today that
number is *asserted* by DOBI (x402 settles the payment, but the metering is trusted). This is the
project's central trust gap. Before real money, add: independent metering attestation (hardware
signature / third-party auditor), a
**staked operator with slashing** for under-reporting, and asset insurance. Until then, every
NAV/yield figure is "trust the operator," and that must be disclosed.

---

## 7. Regulatory framing — handled by DobProtocol's distribution layer

**Scope decision (owner, 2026-07-05): the legal/compliance for the income side is DobProtocol's
responsibility, not dobx's.** B *is* the DobProtocol pool participation token, and DobProtocol's
distribution/marketplace already carries the legal structure (SPV/claim, KYC/AML, geo-fencing) for
holding and trading it. dobx does not re-solve this.

The **USDC-mediated conversion (§5) makes this clean.** Because there is **no on-chain convertible
primitive** anymore — "convert" is just *sell A for USDC on the AMM, then buy B on the DobProtocol
marketplace* — **A is not legally welded to B.** A is a speculative token that trades for USDC; the
regulated income instrument (B) is entered **through DobProtocol's compliant marketplace**, where
its KYC/structure gate lives. The earlier "a convertible into a security is itself a security"
concern was an artifact of the atomic-convertible design that has since been dropped.

What remains, and where it lives:
- **B side (income/ownership, SPV, KYC):** DobProtocol (existing). ✅ inherited.
- **A side (the curve/AMM speculative token):** disclose it is *not* a claim on cash flow and
  carries no yield by itself; keep the marketing honest (don't sell A as "owning the asset's
  income" — that's B). This is a disclosure/marketing discipline, not a new legal structure.
- **Revenue attestation (§6):** the one real remaining trust gap — how much reported revenue is
  actually real. Independent of the legal framing above.

---

## 8. Contract architecture — built vs to build

| Component | Status | Notes |
|---|---|---|
| `AgentShareToken` (A) | ✅ built | fixed-supply ERC-20. A is *not* distributed over, so plain ERC-20 is fine (no snapshot needed). |
| `AgentBondingCurve` + `AgentAMM` (A market) | ✅ built | audit-hardened: graduation seeds AMM at terminal price (no cliff), explicit reserves, gated + pausable launch, deadlines. |
| **Distribution Token (B)** | ✅ external | the **DobProtocol pool participation token** — no new contract; B lives + trades (USDC) on DobProtocol's existing marketplace. Fixed supply, pull-based x402 yield. |
| **Revenue router w/ split** | 🟡 partial | dobx BFF `payout.service` exists but must split `R_net` into `b%` buyback (fund `AgentBuyback`) + `d%` distribution (DobProtocol), bounded 10–50%, idempotent/authed. |
| **`AgentBuyback`** | ✅ built | TWAP/batched buyer of A → treasury; funded (USDC) by real revenue + trading fees; epoch spend cap + min interval; keeper-gated. Tests ✔. |
| **`AgentTreasury`** | ✅ built | A permanently locked (no path out); B strategic reserve owner-deployable (marketplace backstop / incentives); routes USDC fees. Tests ✔. |
| **`AgentConverter` (A→B step 1)** | ✅ built | sells A→USDC on the AMM, skims 0.5–1% fee to treasury, returns net USDC; **no oracle**. Step 2 (buy B) is the DobProtocol marketplace. Replaced the oracle-based `AgentConversion`. Tests ✔. |
| **Attestation / staking** | ❌ to build | metering proof + staked/slashable operator; feeds the revenue split's honesty (no longer feeds conversion — §5/§6). |

**Build order:** (1) ✅ Product-A audit fixes → (2) ✅ buyback + treasury + converter →
(3) revenue router split in the BFF (bounded 10–50%) → (4) attestation/staking → then Foundry
fuzz + external audit. Legal/SPV/KYC runs in parallel and gates any public, real-money launch.

---

## 9. Parameters — signed off 2026-07-05

- [x] **Chain per agent:** creator picks **Base or Stellar** (A and B must share a chain).
- [x] **Revenue split:** configurable per agent, **buyback bounded 10–50%** (distribution ≥50%).
- [x] **Buyback funding mix:** real x402 revenue + curve/AMM trading fees (disclose both fractions).
- [x] **Buyback execution:** **TWAP / batched** (epoch spend cap + min interval; keeper cron).
- [x] **Treasury A:** **non-sellable, permanent**. Treasury B: strategic reserve (~50%), owner-deployable.
- [x] **Conversion `price_B`:** anchored to **USDC via the two open markets — no NAV oracle**.
- [x] **Conversion fee:** **0.5–1%** → treasury. No reserve-depletion throttle (buys existing B on market).
- [ ] **Attestation / operator stake-slash** — still open (§6), the remaining trust gap for real revenue.

Still gating a public real-money launch (out of scope of the contracts): **SPV per asset/basket +
Reg D 506(c)/Reg S + KYC/geo-fence** (§7) and the **revenue attestation** (§6).
