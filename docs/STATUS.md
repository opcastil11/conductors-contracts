# Build status — what exists, where, and how it was verified

> **Cutoff: 2026-08-09.** This document exists because [`TOKENOMICS-V2.md`](TOKENOMICS-V2.md) is
> a *derivation* — it says what should happen — and until now there was no place that said what
> **does** happen. When the two contradict each other, this one wins: the source of truth for this
> file is addresses on Base Sepolia and responses from `https://dobx.pro/api`, not the design.
>
> Writing rule: **nothing goes in here without an address, an endpoint or a script that
> reproduces it.** "It's implemented" without one of those goes in §5 (what's missing), not in §1.

---

## 1. Deployed contracts — Base Sepolia (chainId 84532)

`deployments/baseSepolia.json` (the `deployments/` directory is gitignored: these addresses
only live there, in the production `.env` and in this table).

| Contract | Address | Role |
|---|---|---|
| `DOBX` | `0x7E18D1DE113C7F0D02998f61F2715bA5acE5E3c5` | quote token for all curves (18 dp) |
| `AgentLaunchpad` | `0xA16C303E28F5220196f84fEAa7A1E376f29bd6CA` | `launch()` + `deployController()` |
| `AgentControllerFactory` | `0x8aA347f079B34fD189bD72B5AfeF604F59dDcC3b` | deploys one `AgentController` per agent |
| `KycRegistry` | `0x8c75969aF053a4b4203685b441EDCe9372B077d2` | on-chain mirror of DobProtocol's KYC |
| `platformTreasury` | `0x305DaB055730E0b3AB193051e67ADa3E9BC59142` | DOBX supply + fees + leftover A inventory |

Sources for each contract in `contracts/`: `DOBX.sol`, `AgentLaunchpad.sol`,
`AgentControllerFactory.sol`, `AgentController.sol`, `AgentBondingCurve.sol`, `AgentAMM.sol`,
`AgentShareToken.sol`, `KycRegistry.sol`, `OperatorStake.sol`.

**No longer exist** (deleted in `ab99832`, per §8 of TOKENOMICS-V2): `AgentConverter`,
`AgentBuyback`, `AgentTreasury`, `TokenomicsFactory`. Nothing from the model signed on 2026-07-05
remains in the tree.

## 2. Live agents with the A→B crossing set up

Both came out of real E2E runs, not seeds. They are left in production on purpose: they are
the only live demonstration of the crossing, including the divergence between the *announced* rate
and the *paid* rate. Deleting them is task #7 and is the user's decision.

| Agent | `AgentController` | Retained | Paid rate | Grace |
|---|---|---|---|---|
| `agt_b93f715928fb43baae96` "E2E Cruce" | `0x2AF6794289D75c88a89775aA827DFba0dB57CB33` | 30% | 0.7 B per A | 0 s |
| `agt_fab6265bbe9546409a23` "E2E Ratio" | `0x5C7C185Cc97d1330bdC75D2F4f0c506619e665A6` | 30% | 0.7 B per A | 0 s |

Both: 100,000 USD pool, 36 months, 15% discount, A floor = 0.0824 USD.
Verifiable without credentials: `curl -s https://dobx.pro/api/agents`.

## 3. What is verified against a real chain

Three scripts, all against live Base Sepolia — not local Hardhat, not forks. Each one launches its
own small agent so as not to spend treasury funds observing an arithmetic property.

### 3.1 `scripts/e2e-crossing.js` — the crossing
Buys A on the curve, attaches a controller, activates, converts. Verifies that A is **burned**, that
the converter receives B, that it does **not** receive DOBX, and that the reserve that backed that A
goes out to the `capexSink`. The observed rate is `bOut = aIn × convertibleB / aSupplyAtActivation` — which is
the one that must be shown in the UI, not `1 − retainedBps`: they diverge as soon as the issued B is not 1:1
against the A supply.

### 3.2 `scripts/e2e-grace.js` — grace does close the door
The two previous runs used `graceDays 0`, meaning the grace clock had never been exercised
against real block timestamps. The script activates with a short grace period, checks that
`convert()` **reverts** with a message containing "grace", waits out the clock, and checks that
the *same call* to the *same controller* now succeeds. Result: 0.7 B per A with 30% retained.

> Detail the script documents in the code: `convert()` checks `activated → grace →
> wholeShares > 0 → kyc`, in that order. The first half is grace-only even if the address is
> not approved; the second half needs the mirror written, or it would revert on KYC and it would **look like**
> the grace period never expired.

### 3.3 `scripts/e2e-graduation.js` — graduation without a price jump
The claim in the `AgentBondingCurve` header is "no graduation price cliff". A curve that
graduates into an AMM at a price different from the terminal one hands the gap to the first
post-graduation trader, so what is asserted is **price continuity**, not that `graduated`
has changed to `true`. Measured: **0.109% drift** between the curve's terminal price and
`quoteReserve / shareReserve` of the seeded AMM. The script fails if it exceeds 1%.

### 3.4 Guards that remained in the scripts
- `settled(() => provider.getCode(addr), c => c !== "0x")` — the public Base Sepolia RPC
  returns `0x` for a freshly mined contract; without this every call fails with `BAD_DATA`.
- The leftover A inventory is reported by subtracting what was bought, because in this deployment
  `platformTreasury` **is** the signer and its balance includes the A the script has just bought.

## 4. What exists in the BFF / web (`dobx-pro`, commit `52b8d2f`)

| Piece | Where | Status |
|---|---|---|
| KYC read from DobProtocol | `services/dob.client.js#getKycStatus`, `routes/auth.routes.js` `GET /kyc/status`, `POST /kyc/sync` | ✅ live (401 without JWT, verified in prod) |
| On-chain KYC mirror | `services/evm-launch.client.js#setKycApproved` → `KycRegistry.setApproved` | ✅ live |
| Capped faucet | cap per request, per 24 h window, and cooldown per wallet | ✅ live (429 verified in prod) |
| 400 on malformed addresses | `lib/evm-address.js` (`evmAddress` / `looksEvm` / `maybeEvmAddress`) | ✅ live — previously these were 500s from inside ethers |
| Vesting of retained B | `GET /agents/:id/vesting`, `POST /agents/:id/vesting/release/prepare`, `components/VestingCard.tsx` | ✅ live |

`releaseRetained()` is **permissionless** and always pays the controller's immutable `creator`,
so the card needs no ownership check: a stranger who signs is giving away gas.

## 5. What is NOT built or tested

This is the honest list. Nothing here has an address or an endpoint.

| # | Missing | Why it matters |
|---|---|---|
| 1 | **The real DobProtocol pool as product B.** All E2E runs use `MockParticipation`. | The crossing is tested against a toy ERC-20. See `PUENTE.md` (private dobx-pro repo): the V2 stack on Base **already exists**, it still needs to be wired in. |
| 2 | **The x402 revenue circuit → pool → distribution.** | Without this B pays nothing and the A floor is theory. DOBI was down during the runs. |
| 3 | **End-to-end KYC with a genuinely approved user.** | The 401 and the mirror are tested; the full happy path with a JWT approved by didit.me is missing. |
| 4 | **Mainnet.** Everything lives on Base Sepolia. | — |
| 5 | **Key separation** (today a single key is deployer, owner, treasury, attestor and BFF signer). | See [`OPERATIONS.md`](OPERATIONS.md) §2 — it is the biggest operational risk. |
| 6 | **Immutability of the `AgentController`** — decide and put it in writing. | §7.3-3 of TOKENOMICS-V2: if it is upgradeable without a timelock, it reopens everything it closes. |
| 7 | **DOBX issuance and distribution** (supply, who holds it at launch, how someone who only has USDC gets in). | §7.3-4. |
| 8 | **Numerical calibration of discount ↔ curve** for a real agent. | §7.3-5: without this, §3.4 of TOKENOMICS-V2 is theory. |
| 9 | **Released capex stays in DOBX**, and financing a physical asset forces selling it. | §4.2 — the open item TOKENOMICS-V2 flags as the most urgent, and it is still open. |

## 6. How to reproduce

```bash
cd conductors-contracts                       # .env with PRIVATE_KEY funded on Base Sepolia
npx hardhat run scripts/e2e-crossing.js   --network baseSepolia
npx hardhat run scripts/e2e-grace.js      --network baseSepolia   # GRACE_SECONDS=180 by default
npx hardhat run scripts/e2e-graduation.js --network baseSepolia   # SUPPLY/GRAD_RAISE/SHARES
```

Each script launches its own agent: they do not touch the ones in §2 or the production treasury
beyond the DOBX they spend buying on their own curve.
