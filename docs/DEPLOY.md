# dobx-contracts — Deployment Runbook

Status of the suite (verified 2026-08-08): **47 Hardhat tests passing**, `deploy.js` exercised
locally. This file is the owner step, the canonical launch params, and the per-agent wiring that
turns a launched A market into a two-product agent.

Model reference: **[TOKENOMICS-V2.md](TOKENOMICS-V2.md)**.

---

## 1. Platform deploy (once per network)

The repo has **no `.env`** on purpose (no key committed). To deploy you must supply a funded key.

```bash
cd conductos-contracts

# 1. Fund a throwaway deployer wallet with Base Sepolia ETH
#    (faucet: https://www.alchemy.com/faucets/base-sepolia).

# 2. Create .env (gitignored — NEVER commit it). Minimum:
#    PRIVATE_KEY=0x<funded deployer key>
#    PLATFORM_TREASURY=0x<address that receives the DOBX supply + platform fees>
#    KYC_ATTESTOR=0x<address allowed to flip approvals>   # defaults to the deployer
#    BASE_SEPOLIA_RPC_URL=https://sepolia.base.org        # optional; this is the default
#    BASESCAN_API_KEY=<optional, for verification>
cp .env.example .env && $EDITOR .env

# 3. Deploy DOBX + KycRegistry + AgentControllerFactory + AgentLaunchpad.
npm run deploy:baseSepolia
#   → writes deployments/baseSepolia.json
#     { launchpad, dobx, kycRegistry, controllerFactory, quoteToken, platformTreasury }
```

> **`DOBX_ADDRESS` after the first deploy.** Re-running without it mints a *second* DOBX and
> silently fragments the quote token across curves. Always set `DOBX_ADDRESS` to the existing
> one on every subsequent run. `quoteToken` in the artifact is the same address — it exists so
> the BFF has one stable key to read.

`deployments/<network>.json` is the handoff artifact — the dobx BFF chain-adapter reads these
addresses from it.

**Security:** the deployer key is the launchpad `owner` and the sole `authorizedLauncher` until it
authorizes the dobx backend signer (`setAuthorizedLauncher(backendSigner, true)`). It is also the
only caller of `deployController`. Keep it offline; rotate before mainnet. Do NOT paste it into
chat or commit `.env`.

---

## 2. Canonical launch params (must match the BFF market)

The curve prices per **whole share** in **DOBX (18 dp)**: `price(sold) = basePrice + sold*slope`,
cost = the exact integral. The dobx BFF (`apps/api/.../market.service.js`) mirrors these.

| Param | Value | On-chain (`LaunchParams`) |
|-------|-------|---------------------------|
| Base price | **0.05 DOBX** | `basePrice = 5e16` |
| Slope | **1e-6 DOBX/share** | `slope = 1e12` |
| Terminal price | **0.25 DOBX** | reached at `sold = 200_000` |
| Graduation supply | **200,000 shares** | — |
| Graduation raise | **29,999.9 DOBX** | `graduationRaise = 29999900000000000000000` |
| Total share supply | per-agent (e.g. 1,000,000) | `supply` (whole shares, minted ×1e18) |

Example `launch(LaunchParams)` for a 1,000,000-share agent:
```
name, symbol,
supply           = 1_000_000,
basePrice        = 5e16,     // 0.05 DOBX
slope            = 1e12,     // 1e-6 DOBX per share sold
buyFeeBps        = 100,      // 1% (≤ maxBuyFeeBps 500)
sellFeeBps       = 100,      // 1%
graduationRaise  = 29999900000000000000000
```
`_validateGraduation` requires `graduationRaise < fullIntegral(supply)`, satisfied here.

> ⚠️ **The terminal price is not a free parameter.** It is coupled to the pool's discount rate by
> the rationality constraint of TOKENOMICS-V2 §3.4: `total_produccion / total_shares ≥ P_A`. A
> terminal price above the per-share production makes conversion irrational for everyone and the
> A→B door never opens. Set the curve and the discount rate as **one** decision, not two.

---

## 3. Per-agent wiring — attaching the A→B crossing

`launch()` gives an agent its A market. The crossing is a **second, later** step, because the
controller takes the participation token as an immutable and that token does not exist until the
agent's DobProtocol pool has been created and funded.

Order of operations for one agent:

1. **`launchpad.launch(params)`** → `agentId`, A token, curve. The A market is live and
   permissionless from this moment.
2. **Create the DobProtocol pool** with `payment_token = A`, `payoutMode = 0` (Escrow → splitter),
   the agent's `estimated_apr` as the discount rate, and `participation_to_sale` = 100% − the
   creator's retained share. The pool issues B.
3. **`launchpad.deployController(agentId, ControllerParams)`** — owner-only. Deploys the
   controller and binds it to the curve. Binding is **one-shot**: there is no path to swap in a
   second controller later, so get the params right.
   ```
   participationToken = <B, from step 2>
   capexSink          = <where released DOBX funds the real-world asset>
   retainedBps        = <creator's share of B, in bps; must be < 10000>
   graceSeconds       = <conversion stays closed this long — the attention-market window>
   cliffSeconds       = <retained B: nothing vests before this>
   vestSeconds        = <retained B: linear over this window after the cliff>
   ```
4. **Transfer the pool's B to the controller**, then call **`controller.activate()`** —
   permissionless, and the only moment the cap table is snapshotted. It fixes
   `convertibleB = totalB × (1 − retainedBps)`, `aSupplyAtActivation`, and starts the grace clock.
   Send **all** of the agent's B before activating: B that arrives afterwards is not distributable
   and, because the controller is ownerless, is stuck there permanently.
5. **Approve converters in the `KycRegistry`** (attestor or owner) as they clear compliance.
   Trading A needs nothing; only crossing into B is gated.

After activation every A converts at the same ratio, `convertibleB / aSupplyAtActivation` — so
with 30% retained, 1 A → 0.7 B for the first converter and the last alike.

---

## 4. What is still open

> **Updated 09-08-2026.** Items 2–4 below shipped; the live addresses, the agents that carry a
> crossing, and the three on-chain E2E runs are inventoried in **[STATUS.md](STATUS.md)**. Key
> roles, the threat model and the key-separation plan are in **[OPERATIONS.md](OPERATIONS.md)**.

1. ✅ Contracts complete + tested (42 green).
2. ✅ Deployed to Base Sepolia — see [STATUS.md](STATUS.md) §1.
3. ✅ BFF chain-adapter behind `MARKET_MODE`, live against Base Sepolia.
4. ✅ Web signing flow: approve A → `controller.convert`, wallet-signed, single step.
5. ⛔ TOKENOMICS-V2 §4.2 — released reserve is DOBX while capex is fiat. Converting it to fund an
   asset means selling DOBX, which opposes the sink. Unresolved; do not deploy real capex flow
   until it is. Options written up in `PUENTE.md` (private dobx-pro repo) §6.
6. Foundry fuzz/invariant suite: curve solvency **across conversions**, k-monotonicity, the
   post-graduation LP-shrink price invariant.
7. ⛔ Product B is still `MockParticipation` in every run. Wiring the real DobProtocol pool is
   `PUENTE.md` (private dobx-pro repo) §3 — and note §3.3: the participation token has
   `decimals() == 0`, so pool share granularity decides the minimum conversion.
8. ⛔ Key separation before mainnet — [OPERATIONS.md](OPERATIONS.md) §3. Today one key is deployer,
   owner, treasury, attestor and BFF signer.
