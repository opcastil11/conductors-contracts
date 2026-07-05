# dobx.pro — Tokenomics & Mechanism Design

> Canonical spec for how value flows through a dobx agent. Read this before touching the
> contracts: today the repo implements only **Product A** (the agent token + bonding
> curve/AMM). Product B, the buyback/treasury, and the **conversion** primitive described
> here are the design to build next.
>
> **Status: design proposal, pre-audit.** Parameters marked ⚙️ need final sign-off.

---

## 1. Mental model — a convertible: growth ⇄ income

Each agent has **two tokens**, sold as **two distinct products**, linked by a one-way
**conversion**:

```
   PRODUCT A — Agent Token (growth)              PRODUCT B — Distribution Token (income)
   speculative • bonding curve → AMM             yield-bearing • DobProtocol pool
   "bet on the agent's success"                  "collect the asset's real cash flow"
        │                                                 ▲
        │   ─────────── CONVERSION  A → B  ───────────────┘
        │              (move from upside to income, one-way, NAV-anchored)
        │
   BUYBACK ◄── funded by a MIX: real x402 asset revenue + curve/AMM trading fees
        │
        └────► TREASURY  (accumulates repurchased A; holds the B convertible reserve)
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

> ⚙️ **Chain decision:** A and B must live on the **same chain per agent** so conversion is
> atomic. DobProtocol supports Stellar + Base; the curve/AMM contracts are EVM. → default to
> **Base** for agents that use the fair-launch/convertible model.

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
is the core tokenomics knob and the point of tension between the two investor classes. It
must be **fixed and disclosed per agent at launch** (not operator-adjustable after the fact).

> ⚙️ **Revenue split** `R_net = R_gross − costs − fees`, then `R_net = b%·buyback +
> d%·distribution`. Recommend a conservative, disclosed default (e.g. `b=30% / d=70%`) so
> the income product stays the anchor and the buyback is a supplement, not the main draw.

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
- **Treasury governance:** who controls treasury A, and can it ever be sold back into the
  market (dumping on holders)? → default: treasury A is **non-sellable**, usable only to back
  conversions or provide protocol-owned liquidity. ⚙️ confirm.

---

## 5. Conversion A → B (the bridge) — recommended design

This is the new primitive and the one non-obvious economic decision. **The naive version is
unsafe**, so the recommended design is specific.

### Why a fixed peg is wrong
Real cash flow `R` is **fixed** by the asset. B holders split `R` pro-rata, so
`yield_per_B = R / B_supply`. If conversion **mints new B** at a fixed rate with no cap, then
every conversion grows `B_supply` and **dilutes every B holder's yield toward zero**. A 1:1,
unbounded, mint-on-convert design collapses the income product. **Do not do this.**

### Recommended mechanism
1. **B supply is fixed** (it's fractional ownership of the asset's cash flow). Conversion does
   **not mint** B — it **transfers existing B out of the treasury reserve**.
2. At launch, allocate a **convertible reserve** of B into the treasury (⚙️ e.g. 40–60% of B
   supply). The rest of B is sold directly as Product B (primary income sale).
3. **Conversion is one-way (A → B only).** A holder deposits/burns A and receives B from the
   treasury reserve. One-way avoids a bidirectional arbitrage loop and makes A monotonically
   deflationary as the ecosystem matures toward income.
4. **Rate is anchored to value (NAV), not fixed.** You receive B worth (approximately) the
   market value of the A you convert:
   `B_out ≈ (price_A / price_B) · A_in`, where `price_B` reflects B's yield-backed fair value
   (its market/pool price or a NAV oracle of discounted future cash flow). This makes
   conversion **arbitrage-neutral**: A can never trade far below "the B you'd get by
   converting," which is exactly the **fundamental floor** that ties A to real yield.
5. **Reserve exhaustion is the natural cap.** When the treasury's B reserve runs low,
   conversion throttles/stops — which automatically bounds `B_supply` in circulation and
   protects per-B yield. The buyback keeps refilling the treasury with A (value), and the
   protocol can top up the B reserve from the fixed allocation, never beyond it.

### Result
- **A holders** get: momentum upside + buyback support + a real-yield floor via convertibility.
- **B holders** get: stable pro-rata yield, protected from dilution because supply is fixed and
  conversion draws from a bounded reserve, not a mint.
- **The two products stay coherent:** the same real revenue funds (a) the buyback that supports
  A and refills the treasury, and (b) the distribution that pays B — split by the disclosed
  `b%/d%`.

> ⚙️ **Open parameters:** convertible reserve size, `price_B` source (pool price vs NAV
> oracle), conversion fee (if any), throttle curve as the reserve depletes.

---

## 6. The oracle dependency (unavoidable)

Both the **revenue split** (§3) and the **conversion rate** (§5, if NAV-based) depend on the
asset's **real reported revenue**. Today that number is *asserted* by DOBI (x402 settles the
payment, but the metering is trusted). This is the project's central trust gap. Before real
money, add: independent metering attestation (hardware signature / third-party auditor), a
**staked operator with slashing** for under-reporting, and asset insurance. Until then, every
NAV/yield figure is "trust the operator," and that must be disclosed.

---

## 7. Regulatory framing (must read before launch)

Making A **convertible into B** (a yield-bearing instrument) pulls **the entire structure**,
A included, into securities treatment — a convertible into a security is itself a security.
This is not avoided by the "utility token" framing. Consequences that gate a public launch:
- **SPV per agent/basket** so B (and A-via-conversion) represents a real legal claim on the
  asset's cash flow; otherwise holders own nothing enforceable.
- **KYC/AML + accreditation/geo-fencing** on **both** the A sale and the B sale — the
  launchpad cannot be a KYC-free door into a regulated instrument.
- **Reg D 506(c) + Reg S** (or Reg A+ for retail) rather than a permissionless fair launch.
- Disclosures covering the split, buyback, conversion, operator, and asset risks.

See the audit's product review for the full analysis; legal is the critical path, not code.

---

## 8. Contract architecture — built vs to build

| Component | Status | Notes |
|---|---|---|
| `AgentShareToken` (A) | ✅ built | fixed-supply ERC-20. **Must become snapshot/checkpoint-capable** only if ever distributed over — but in this model A is *not* distributed over, so plain ERC-20 is fine. |
| `AgentBondingCurve` + `AgentAMM` (A market) | ✅ built | audit fixes required before mainnet: graduation price-cliff, `balanceOf` reserves, `launch()` gating, pausing, MEV. |
| **Distribution Token (B)** | ❌ to build | the DobProtocol participation token / pool for the agent. Fixed supply. Receives x402 revenue pull-based. |
| **Revenue router w/ split** | 🟡 partial | dobx BFF `payout.service` exists but must split `R_net` into `b%` buyback + `d%` distribution, and be idempotent/authed (see backend audit). |
| **Buyback executor** | ❌ to build | TWAP/batched buyer of A → treasury; funded by real revenue + trading fees. |
| **Treasury** | ❌ to build | holds repurchased A (non-sellable) + the B convertible reserve. |
| **Conversion contract (A→B)** | ❌ to build | one-way, NAV-anchored, draws B from treasury reserve, throttles on depletion. **The key new contract.** |
| **Oracle / attestation** | ❌ to build | metering proof + staked operator; feeds split + conversion rate. |

**Build order (recommended):** (1) fix Product-A audit criticals → (2) B token + revenue
split in the router → (3) buyback + treasury → (4) conversion contract → (5) oracle/staking.
Legal/SPV/KYC runs in parallel and gates any public, real-money launch.

---

## 9. Open parameters (sign-off checklist) ⚙️

- [ ] Chain per agent (recommend Base for the convertible model)
- [ ] Revenue split `b% buyback / d% distribution` (recommend 30/70)
- [ ] Buyback funding mix: % from x402 real vs % from trading fees (disclose both)
- [ ] Buyback execution: TWAP / batched / private mempool
- [ ] Treasury A: non-sellable? governance?
- [ ] B total supply + convertible reserve size (recommend reserve 40–60% of B)
- [ ] Conversion `price_B` source: pool price vs NAV oracle
- [ ] Conversion fee + depletion throttle curve
- [ ] Oracle/attestation design + operator stake/slashing
