# Tokenomics v2 — one-way A→B model over *future revenue* pools

> **Status: CURRENT. 2026-08-08.** Supersedes [`TOKENOMICS.md`](TOKENOMICS.md) (signed
> 2026-07-05), which remains as the historical record of the buyback/converter/treasury model.
> This document is the full derivation; the browsable version, with per-component build status,
> lives at `conductors.io/arquitectura` (`dobx-pro/apps/web/src/pages/ArchitecturePage.tsx`, in the private Conductors app repo).
>
> Notation:
> **✅ verified** = confirmed by reading the code, with reference · **▶ decided** = decision
> made, not yet built · **❓ open** = still to be decided.
>
> **Update 2026-09-30 — B is an open pool, not a loan.** Product decision: B is no longer
> modeled as factoring (requested amount, discount rate, term, amortization down to zero).
> B is a **free to join** pool with no term: once stage A ends, you enter **by crossing A**
> (one direction only), whatever the agent's assets earn is deposited into the pool and
> distributed pro rata, and you exit **by selling B** on the marketplace. No promised return. The
> contracts do not change: the factoring numbers never reached the chain (they lived in the BFF and in
> `pool_data`). Sections §2-B, §3.3, §3.4 and §6 are rewritten for this model.
>
> **Update 2026-08-09.** The original line of this banner said "none of this model is
> built yet". **That is no longer true, so it is withdrawn**: the contracts are deployed on
> Base Sepolia, and the crossing, the grace period and graduation are verified against the live chain. This
> document is still the *derivation* — what must happen. What **does happen** lives in
> [`STATUS.md`](STATUS.md), and whenever the two contradict each other, STATUS wins. The keys and their
> powers are in [`OPERATIONS.md`](OPERATIONS.md).
>
> Two substantive corrections, both derived from reading DobProtocol's deployed code:
> **(a)** the A↔B "bridge" does not exist as a problem — DobProtocol already issues participations on Base
> mainnet, see `dobx-pro/docs/PUENTE.md` (private Conductors app repo); **(b)** the pool admin
> **cannot** be the `AgentController` (§3.2 is corrected below).

---

## 0. What changes relative to the signed model

The signed model had two products sold separately, connected by a
"sell A for USDC, buy B on the marketplace" flow (§5 of `TOKENOMICS.md`), and sustained by a
revenue-funded buyback. This model replaces it with **a single entry path (A),
a one-way A→B conversion, and the DobProtocol future revenue pool as the sole destination of
revenue.**

| Component | Signed model | Current model |
|---|---|---|
| Curve quote token | USDC | **DOBX** — platform token, Virtuals model |
| Market for A | curve → AMM | **same**, but the pair is A/DOBX |
| Market for B | DobProtocol marketplace, own price in USDC | **primary: only with A**; exit: exit liquidity / marketplace in USDC |
| A→B bridge | sell A for USDC, buy B (2 steps, not atomic, fee 0.5–1%) | **one-way 1:1 conversion, same cap, burning A** |
| Pool admin | operator wallet | **`AgentController`** — a contract, not a wallet |
| `AgentConverter` | ✅ built | **removed** |
| `AgentBuyback` + TWAP + keeper | ✅ built | **removed** |
| `AgentTreasury` (B reserve, backstop) | ✅ built | **removed** |
| `TokenomicsFactory` | ✅ built | **removed** |
| Revenue split | operator% / buyback% (10–50%) / distribution% | **100% to the pool**; every cut happens inside the cap table |
| `operator_split_bps` (Conductors BFF) | 30% off-the-top | **removed** |
| Operator profit | off-the-top split + treasury | **retained `participation_to_sale`**, held in custody by the controller |
| Floor of A | indirect arbitrage across two markets | **mechanical `P_A ≥ P_B`**, with an FX term; `P_B` is a market price |
| Capex financing | undefined (conflict with the curve reserve) | **reserve release on burning A** — ❓ with one open edge (§4.2) |
| Legal status of A | "A is not welded to B" | **KYC gate at the A→B crossing, inside DobProtocol** |

Contract surface that disappears: converter, buyback, treasury, factory, TWAP execution,
keeper cron, per-epoch cap, and all the associated MEV surface. Added: `AgentController` and
the `DOBX` token.

---

## 1. The complete model

```
        DOBX
          │  buy on the curve (price rises $0.05 → terminal)
          ▼
    ┌───────────┐   one-way 1:1 conversion, same cap
    │  TOKEN A  │───────────────────────────────────────────┐
    │ perpetual │   · the paid-in A is burned/immobilized   │
    │ speculat. │   · releases its reserve share → capex    │
    └───────────┘                                            ▼
          ▲                                        ┌──────────────────┐
          │ sell on the AMM (A's only exit)        │     TOKEN B      │
          ▼                                        │     open pool    │
        DOBX                                       │ no term; you exit│
                                                   │  by selling B    │
                                                   └──────────────────┘
                                                        │         │
   x402 (DOBI) ──── 100% of revenue ────────────────────┘         │
                    lands in the pool                              │
                                                                   ▼
                                              USDC distribution per schedule
                                              (starts after the grace period)
                                                                   │
                                                                   ▼
                                              exit: exit liquidity (LPs with USDC)
                                                      or secondary marketplace
```


Two markets with different prices, a floor connecting them, and a migration from one to the other that
is also the financing mechanism.

---

## 2. The two products

### A — agent token (perpetual, speculative)

- Fixed-supply ERC-20, bonding curve that graduates to an AMM. Already built
  (`AgentShareToken`, `AgentBondingCurve`, `AgentAMM`).
- **Quoted against DOBX, not USDC.** ▶ Virtuals model: the platform token is the
  currency of every agent, so every launch and every purchase is a DOBX sink.
- Receives no distributions. Its link to revenue is **the right to convert**.
- Its market is permissionless: the KYC gate is at the crossing into B, not here (§7.1).
- It lives in the attention market: its window of speculative value is short by nature, and
  the design protects it with the grace period (§6).

**✅ verified — changing the quote token does not require rewriting contracts:**
`AgentLaunchpad.setQuoteToken()` is `onlyOwner` and emits `QuoteTokenUpdated`
(`AgentLaunchpad.sol:87`). But `AgentBondingCurve.quoteToken` is `immutable`
(`AgentBondingCurve.sol:32`): each curve fixes its quote at deployment.

> **Consequence:** agents already launched are tied to MockUSDC forever — MSOL
> included. Migrating to DOBX means **relaunching**, not reconfiguring.

### B — participation in an open DobProtocol pool

B is the participation in the agent's pool. **It is not a loan**: there is no requested amount, discount
rate or term, and the pool does not close when it "finishes paying" — it pays as long as the agent
operates and earns.

- **Entry:** only by crossing A, once stage A ends and the grace period expires. The pool does not issue B
  for sale.
- **Revenue:** whatever the assets earn (x402) is deposited into the pool and distributed pro rata.
  Pull-based collection: the holder **claims**; nobody transfers to them.
- **Exit:** sell B on the secondary marketplace (settles in USDC).
- Fixed supply, percentage-based cap table (`submitInit({ participants: [{address, percentage}] })`).

The DobProtocol pool comes with loan fields (`estimated_apr`, `total_sale_pool_asked`,
`distribution_dates`/`duration`; see `Dober-MVP/back-end/services/poolUtils.service.js:341`).
Conductors does not use them: on Base they do not reach the chain, and on the Stellar route they are sent as 0 / empty.

---

## 3. The A→B conversion

### 3.1 Mechanics

**✅ verified — DobProtocol accepts an arbitrary payment token, independent of the distribution token:**

| Route | Reference | What it accepts |
|---|---|---|
| Stellar crowdfunding | `stellar.service.js:1089` — `init(admin, payment_token, price_per_share, soft_cap, hard_cap, deadline, payout_mode)` | any SAC |
| EVM sale | `evm-pool.service.js:322` — `prepareCreateSale({participationToken, paymentToken, price})` | any ERC-20 (`0x0` ⇒ ETH) |
| Secondary marketplace | `payment_token_address` **per listing** (`stellar-marketplace.service.js`) | whatever the seller chooses |
| Exit liquidity | `payment_token_address` **per LP offer** (`stellar-exit-liquidity.service.js`) | whatever the LP chooses |

Distribution is separate: `prepareDistribute({ tokenAddress })` — it is paid in **USDC**.

▶ **The design:**
- Pool crowdfunding campaign with **`payment_token = A`**, `price_per_share` such that
  **1 A = 1 B**, and `total_shares(B) = total_supply(A)` (same cap).
- **`payoutMode = 0` (Escrow)** — ✅ verified in `stellar.service.js:1099`: mode 0 sends the
  funds to the **splitter** (the pool contract) on `activate()`; mode 1 (`DirectToOwner`) sends them
  to the **admin wallet**. Mode 0 is what prevents the operator from keeping the A
  raised. Today `dobx-pro/apps/api/src/services/tokenize.service.js` does not pass this parameter.
- The A that enters the splitter **remains permanently immobilized**.

**It is one-way.** There is no B→A. Whoever converted, converted.

### 3.2 `AgentController` — why "burned" is a guarantee and not a promise

The escrow leaves the A in the splitter, but that only helps if nobody can take it out. The
open question was whether `soro_splitter` exposes an admin sweep (the repo only contains the
compiled `.wasm`, `stellar.service.js:74`).

▶ **The decision avoids having to answer it:** the pool admin **stops being a wallet** and
becomes a contract, the `AgentController`, which exposes no function to move those
funds. If the call does not exist at the only address that could make it, it does not matter whether the splitter
has it.

The same contract absorbs the other rule that was needed:

- **Converted A stays immobilized** — with no withdrawal surface, "immobilized" and "burned"
  are functionally the same.
- **The B retained by the creator lives inside it**, with its cliff and schedule enforced by
  code (§5.3).

> ❓ **Open and critical: the guarantee is only as good as its upgrade key.** An
> upgradeable controller without a timelock reopens everything it closes — whoever can change it can add the
> sweep later. It must be **immutable**, or its key burned or behind a timelock
> long enough for the market to react.

> ⛔ **Correction 2026-08-09 — "the pool admin is the controller" is not implementable.**
> Against the `PoolMasterV2` that DobProtocol has deployed on Base, `createTreasuryPool` makes
> `users[0]` the pool owner, and in the v2 logic (audit 2026-08, finding B-1)
> `createDistribution` is **owner-only**. `AgentController` has no call passthrough, so
> making it the owner would leave the pool **with nobody able to distribute**.
>
> The correct separation: **pool owner** = whoever operates the distributions (a wallet);
> **`AgentController`** = custodian of B and sole issuer of the conversion ratio. What this
> §3.2 meant to guarantee **is not lost** — it is still true that nobody can take B away from a
> converter, change the ratio after `activate()`, or move quote to any destination other than the
> `capexSink`. What falls is the sentence "the pool admin is a contract, not a wallet".
> Full derivation in `dobx-pro/docs/PUENTE.md` §4 (private Conductors app repo).

### 3.3 Price relationship

Arbitrage runs in one direction only: if `P_B > P_A`, you buy A, convert, sell B — that
pushes `P_A` up. If `P_B < P_A` there is nothing to do. Therefore:

```
P_A ≥ P_B          →          A = B + speculative premium
```

- **A has a floor.** The income market puts a floor under the speculative market.
- **A can trade above it without limit.** The premium is the speculation, and it is not arbitraged.
- **The floor is market-driven.** `P_B` is what the marketplace pays for B, which tracks what the
  agent earns. There is no "owed" figure that fixes it or makes it decay; Conductors shows the
  crossing ratio, not a computed floor.

**With DOBX as quote, the floor carries an exchange-rate term.** A is quoted in DOBX and B
distributes in USDC, and the conversion is 1:1 in **units**, not in value:

```
P_A(DOBX) × DOBX/USDC  ≥  P_B(USDC)
```

> ❓ Consequence to accept or mitigate: **if DOBX falls, the floor of A measured in DOBX rises.** The floor
> still exists, but DOBX volatility propagates to all agent markets at
> once.

**And the arbitrage can only be executed by those who pass KYC** (§7.1). For the rest of the market, A floats
with no floor. That is the price of resolving the legal question at the crossing, and it is accepted.

### 3.4 Converting has to pay off

Crossing hands over something worth `P_A` for something worth `ratio × P_B`. Whoever bought A high on the
curve may have no incentive to cross until B trades above that. The curve's terminal price is
the creator's dial that sets that ceiling (`agents.terminal_price`, default 0.25 DOBX).
Since B no longer promises a total production, **there is no a priori check**: the market
for B decides. (The previous version of this section tied the terminal price to `total_produccion / shares`;
that term no longer exists.)

---

## 4. Financing: capex comes from conversions

### 4.1 The argument

**A bonding curve is not a capital raise, it is a market maker with a balance sheet.** What
comes in when someone buys A is not money raised: it is the **reserve** the curve uses to
pay whoever sells later. It is a liability. `AgentBondingCurve` has explicit reserves.

If the operator spends that reserve on the asset, the result is a fractional-reserve system that
works only as long as more comes in than goes out:

```
curve sells 200k A                        → reserve = 30k DOBX
operator spends 25k on the charger        → reserve = 5k DOBX
holders of 100k A exit                    → need 15k DOBX → the curve goes bust
```

**Conversion solves exactly this.** Every A converted to B is permanently removed from the
sell side of the curve; its share of the reserve stops being a buyback liability. Hence
the rule:

> ▶ **Capex is not financed with the raise. It is financed with conversions.** The reserve stays
> 100% backed for all unconverted A. When an A is burned, the curve releases what it would have
> paid to buy it back, and that goes to the asset.

The incentive aligns itself: **to finance the asset, the operator has to make conversion
attractive** — that is, has to make the revenue real. There is no way to
take the money out without someone voluntarily giving up their resale right.

### 4.2 The edge that DOBX opens

❓ **Once the curve moves to DOBX, what the burn releases is no longer USDC.** Turning it into a
physical asset requires **selling it for USDC** — that is, selling pressure on the platform's own
token right when the agents start operating, which is exactly when you don't
want it. It is the flip side of the sink: **DOBX rises when agents launch and falls when they are financed.**

Options on the table, none chosen:
1. Market sale, accepting the impact.
2. A platform USDC fund that buys the released DOBX.
3. The operator advances the capex against their retained B.

**It is the most urgent pending item in the model.**

### 4.3 Fit criterion

The grace period (§6) is designed so that **nobody converts during the first year**. That
means **zero capex financing in year 1**.

▶ **Therefore this model fits already-financed assets**, not raises for
new capex. That path already exists in the code: `tokenize.service.register({ linkedPools })`
links already-tokenized DobProtocol pools that the agent takes over operating. In that case the grace
year is the operator recovering their capex before starting to distribute — a standard
project finance structure.

---

## 5. The revenue waterfall

### 5.1 All revenue lands in the pool

▶ **`operator_split_bps` is removed.** Today `dobx-pro/apps/api/src/config.js` deducts 30% of the
gross **before** the money reaches the pool. That breaks two things:

1. **The audit.** If the pool address is the audit point — which is the reason why
   in practice opex and profit get mixed there — then an upstream cut leaves the
   on-chain trail incomplete.
2. **The published APR.** DobProtocol computes the return from the pool's numbers
   (`poolUtils.service.js:341`), which know nothing about the prior deduction. The pool promises a
   total production that will never arrive in full.

> **Rule: 100% of x402 revenue lands at the pool address. All cuts happen
> inside the cap table.**

### 5.2 The operator's profit lives in `participation_to_sale`

**✅ verified:** `pool_data.participation_to_sale` is literally "percentage of pool for
sale" and `calculatedApr` already uses it (`poolUtils.service.js:344`). It is not a new feature — it is a
field that Conductors does not expose today: `tokenize.service.completeInit` puts in
`participants: [{ operator, 100 }]` and never sets `participation_to_sale`.

▶ **The tokenization wizard asks the creator what % of future revenue they retain.**
That % covers their opex and their profit, mixed together.

**Consequence that must be disclosed:** the operator absorbs opex volatility, not the
investors. It is a gross-lease structure. It is defensible and simpler, but it requires
stating it explicitly ("the operator bears the opex").

❓ The realistic retention floor per asset type (charger / solar / vending) **is deferred**:
it is not a problem today, and it will be calibrated with real operating data instead of guessed now. The
risk to watch is that if opex persistently eats the retention, the operator
abandons the asset and the pool dies.

### 5.3 Lockup of retained B

▶ **Solved by the `AgentController` (§3.2).** Retained B is held in custody by the controller, which
enforces the cliff and the schedule in code, so the creator cannot list it on the
secondary marketplace before the investors.

(Exit liquidity was **not** the vector: there the LP deposits USDC and *buys* shares with
`discount_bps` — `stellar-exit-liquidity.service.js:71`; the one exiting is the one who pays the discount.)

---

## 6. The creator's parameters

The design does not fix values: it defines **a space the creator navigates**. All of them are in the
dobx-pro wizard ("Fase A → B" step). There is no amount, rate or term: B is an open pool.

| # | Parameter | Where it lives |
|---|---|---|
| 1 | Curve terminal price | `AgentBondingCurve` slope |
| 2 | **Grace period before opening the crossing** | `AgentController.graceEndsAt` |
| 3 | % of B retained by the creator | `AgentController` (`retainedBps`) |
| 4 | Cliff / vesting of the retained portion | `AgentController` |

### 6.1 The grace period — the phase separator

It is the piece that keeps the two products from cannibalizing each other:

- **During the grace period (e.g. 12 months):** B pays nothing. Converting means handing over a liquid
  token for paper that does not yield yet → **nobody converts**. A keeps its full float and
  has the entire window of the attention market, which is where its value lives and which decays quickly
  by nature.
- **When the grace period ends:** converting becomes rational and A starts draining into B.

The floor `P_A ≥ ratio × P_B` **exists from day one** even though nobody can collect yet.

### 6.2 The couplings (this is what the wizard has to show)

- **Terminal price (#1) ↔ incentive to cross.** A high terminal leaves the last buyers
  of A with no reason to cross until B trades above it (§3.4).
- **Grace period (#2) ↔ retention (#3).** More grace = more prominence for A = the creator can
  afford to retain less of B. And vice versa.
- **Retention (#3) ↔ floor of A.** Each retained point lowers the floor proportionally: with 30%
  retained, the floor of A is 70% of what it would otherwise be. **The creator's retention and the strength of the
  link between the two markets are the same knob seen from two sides.**

### 6.3 Presets

▶ Reference profiles (the wizard currently exposes the dials individually, with validations):

| | **Attention profile** | **Income profile** | **Balanced** |
|---|---|---|---|
| Grace period | long (18–24m) | short (0–6m) | 12m |
| Retention | high | low | medium |
| Curve | high terminal | low terminal | medium |
| Outcome | A takes the lead, B late and small | B takes the lead, A drains quickly | gradual migration |

---

## 7. Decisions made and what remains open

### 7.1 The legal decision — resolved at the crossing

`TOKENOMICS.md` §7 held that A was clean **precisely because it was not welded to B**, and
the natural objection to this model was that the 1:1 link turns A into the only access path
to an instrument that distributes cash flow — that is, under Howey, probably a security.

▶ **Decision: the gate is at the crossing, not at the curve.** A is a platform token, as in
Virtuals, and its market is permissionless. The A→B conversion **happens only inside
DobProtocol**, so whoever crosses goes through the KYC and compliance already built there
for B. The instrument that distributes cash flow never leaves a regulated environment, and the
curve does not carry that burden.

**It is no longer blocking.** The residue is economic, not legal, and it is accepted: the arbitrage that
sustains `P_A ≥ P_B` only exists for users who can cross; for everyone else, A floats with no
floor (§3.3).

### 7.2 Status of the five questions that were open

| # | Topic | Resolution |
|---|---|---|
| 1 | Does `soro_splitter` have an admin sweep? | ▶ **No longer matters.** The admin is the `AgentController`, not a wallet (§3.2). |
| 2 | Discount ↔ curve calibration | ▶ **Virtuals model with DOBX as quote token** (§2). Numerical calibration is still pending (#3 below). |
| 3 | Retention floor per asset type | ▶ **Deferred.** Not a problem today; calibrated with real data (§5.2). |
| 4 | Vesting of retained B | ▶ **Solved by the `AgentController`** (§5.3). |
| 5 | Legal status of A | ▶ **Solved: KYC at the crossing** (§7.1). |

### 7.3 What these decisions leave open

Consequences, not objections: each one stems from one of the resolutions above.

| # | Topic | Section | Type |
|---|---|---|---|
| 1 | **Released capex stays in DOBX**, and financing a physical asset forces selling it. | §4.2 | ❓ decide — the most urgent |
| 2 | **The floor of A is exposed to DOBX FX**; its volatility propagates to all agents. | §3.3 | ❓ decide |
| 3 | **Immutability of the `AgentController`**: if it is upgradeable without a timelock, it reopens everything it closes. | §3.2 | ❓ decide |
| 4 | **DOBX issuance and distribution**: supply, who holds it at launch, how a buyer holding only USDC gets in. | §2 | ❓ decide |
| 5 | **Calibration of the terminal price** against what B trades at for a real agent (§3.4). | §3.4 | ❓ decide |
| 6 | **The arbitrage only exists for those who pass KYC.** | §3.3 | accepted |
| 7 | Revenue attestation (`OperatorStake` already built, the attestation itself not). | — | inherited from `TOKENOMICS.md` §6 |
| 8 | **Granularity of B.** DobProtocol's `ParticipationToken` has `decimals() == 0` and the share limit is 10 000 000. If the pool is created with percentages 1–100, every normal conversion reverts with `"dust"`. | PUENTE §3.3 | ❓ decide before wiring |
| 9 | **Pool-owner / controller separation** and its consequence in the UI (showing 0-decimal amounts). | PUENTE §3.4, §4 | ▶ decided here, still to build |

---

## 8. Impact on the code

> **Status 2026-08-09:** this section was written as future work and no longer is. The three
> tables are **executed** except for what [`STATUS.md`](STATUS.md) §5 flags. What remains
> pending from this chapter, specifically: **calibrating** the terminal price against production
> per share (still open), and **wiring the real pool** instead of `MockParticipation`
> (see `dobx-pro/docs/PUENTE.md` §3, private Conductors app repo).

### `conductors-contracts`
| Action | What |
|---|---|
| Create | **`DOBX`** (platform token), **`AgentController`** (pool admin + custody of retained B with cliff) |
| Remove | `AgentConverter`, `AgentBuyback`, `AgentTreasury`, `TokenomicsFactory` |
| Modify | `AgentBondingCurve`: reserve release against burning of A (§4) |
| Keep | `AgentShareToken`, `AgentAMM`, `OperatorStake` |
| Configure | `AgentLaunchpad.setQuoteToken(DOBX)` — and **relaunch** existing agents (§2) |
| Calibrate | curve terminal price against the pool's production per share (§3.4) |

### `dobx-pro/apps/api`
| File | Change |
|---|---|
| `services/tokenize.service.js` | pass `payoutMode = 0`, `payment_token = A`, admin = `AgentController`, `participation_to_sale`, grace period, discount and duration when creating the pool; stop hardcoding `participants: [{operator, 100}]` |
| `services/payout.service.js` | remove `operator_split_bps` and all buyback logic (`buyback_bps`, `buyback_address`, leg 1); the router keeps only the distribution leg |
| `services/evm-launch.client.js` | remove `fundBuyback`, `deployTokenomics` |
| `config.js` | remove `defaultOperatorSplitBps` |
| `db.js` | migrate: drop `buyback_bps`, `buyback_address`, `converter_address`, `treasury_address`; add `controller_address` and the creator's pool config |
| `services/market.service.js` | `convert()` stops being "sell A + buy B at $1"; it becomes the contribution to the campaign. `TERMINAL_PRICE` is no longer hardcoded |
| `routes/agents.routes.js` | remove the `$1 = 1 B` mock; B is acquired only through conversion |

### `dobx-pro/apps/web`
| What | Change |
|---|---|
| Tokenization wizard | the 5 parameters of §6 with presets and live couplings |
| Agent page | show grace period, schedule, remaining production, current floor of A, % retained by the creator |
| Conversion flow | one step (contribute A to the campaign), not two |
| Trading | prices in DOBX, not USDC |

---

## 9. Executive summary

1. **A single entry path:** DOBX → A (curve/AMM), Virtuals model. A is perpetual,
   speculative, and its market is permissionless.
2. **A one-way 1:1 conversion with the same cap** into B, which is the participation in a
   DobProtocol pool — **open**: no amount, rate or term; you exit by selling B.
3. **Converted A is immobilized** (crowdfunding with `payment_token = A` and `payoutMode = 0`),
   and that burn is what releases curve reserve toward the asset's capex.
4. **The `AgentController` is the pool admin**, not a wallet: that turns "immobilized" into
   a verifiable guarantee and enforces the cliff on retained B.
5. **100% of x402 revenue lands in the pool.** All cuts live in the cap table. The
   operator's profit is their retained `participation_to_sale`, pari passu with the investors.
6. **The grace period separates the phases:** year 1 is pure attention market for A; afterwards,
   migration toward income.
7. **The legal side is resolved at the crossing:** DobProtocol KYC/compliance on the A→B step.
8. **The creator navigates five coupled parameters**, with presets that make the
   trade-offs visible — today they would make them blind because none is exposed.

Removed: buyback, converter, B treasury, factory, oracles, TWAP, keeper, MEV, and the
off-the-top split. Gained: a single entry price, a mechanical floor for A, self-aligned
financing, a full audit at the pool address, and a real sink for DOBX.

Paid for with: **the fit restricted to already-financed assets** (§4.3), **the exposure of the floor
of A to DOBX FX** (§3.3), and above all **the tension between the DOBX sink and capex
financing** (§4.2), which is the most urgent pending item.
