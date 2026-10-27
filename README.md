# conductors-contracts

**On-chain layer of [dobx.pro](https://dobx.pro): a launchpad that gives every real-world-asset
agent a fair-launched market token, and a one-way door from that token into the asset's revenue.**

[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636?logo=solidity)](https://soliditylang.org)
[![Hardhat](https://img.shields.io/badge/Built%20with-Hardhat-f7df1e)](https://hardhat.org)
[![Foundry](https://img.shields.io/badge/Fuzzed%20with-Foundry-black)](https://getfoundry.sh)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.x-4e5ee4)](https://openzeppelin.com/contracts)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> [!WARNING]
> **Pre-audit.** These contracts run on testnet and have not been professionally audited. Do not
> deploy them to mainnet with real funds.

---

## Overview

Each agent on dobx.pro operates a real asset (through **DOBI**) whose revenue is distributed by
a **DobProtocol** pool. The agent exposes two distinct products:

| | **A — agent token** | **B — revenue participation** |
|---|---|---|
| Nature | Perpetual, speculative market token | Finite, amortizing claim on future revenue |
| Access | Permissionless trading | KYC required |
| Issued by | This repo (`AgentShareToken`) | DobProtocol pool |
| Pays out | Nothing directly — its value is the **right to convert** | 100% of the revenue that reaches the pool |
| Market | Bonding curve → locked-liquidity AMM, quoted in **DOBX** | DobProtocol |

Holders can convert **A → B** once and irreversibly. Conversion burns A, releases the curve
reserve that backed it to fund the asset's capex, and hands back B at a pro-rata ratio fixed at
activation. B can never be turned back into A.

## Architecture

```
                 AgentLaunchpad.launch()
                          │
          ┌───────────────┴────────────────┐
          ▼                                ▼
   AgentShareToken (A)            AgentBondingCurve ── buy / sell in DOBX
   fixed supply, minted                    │          price = base + sold · slope
   into the curve                          │  raised ≥ graduationRaise
                                           ▼
                                  AgentAMM (x·y = k, 0.3% fee)
                                  seeded at the curve's terminal price,
                                  LP locked forever

          ── once the agent's DobProtocol pool exists ──

   AgentLaunchpad.deployController()
          │
          ▼
   AgentController ── convert(A) ──►  burn A
          │                           release backing reserve ──► capexSink
          │                           transfer B ──► holder (KycRegistry-gated)
          └── vests the creator's retained B (cliff + linear)
```

## Contracts

| Contract | Responsibility |
|---|---|
| [`DOBX`](contracts/DOBX.sol) | Platform token and quote asset of every curve. Fixed 1e9 supply minted to the treasury, no mint function, burnable. |
| [`AgentLaunchpad`](contracts/AgentLaunchpad.sol) | Factory and registry. `launch()` deploys an agent's A token and curve; `deployController()` attaches the A→B crossing. Gated and pausable. |
| [`AgentShareToken`](contracts/AgentShareToken.sol) | Fixed-supply ERC-20 for one agent's A. No owner, no mint after launch; holder-burnable. |
| [`AgentBondingCurve`](contracts/AgentBondingCurve.sol) | Linear curve priced per whole share in DOBX. Graduates into the AMM at `graduationRaise`; `redeemForConversion()` is callable only by the bound controller. |
| [`AgentAMM`](contracts/AgentAMM.sol) | Constant-product AMM for A ↔ DOBX with explicit reserves (donation-proof). |
| [`AgentController`](contracts/AgentController.sol) | The crossing. Immutable and ownerless: snapshots supply at `activate()`, enforces a grace period and KYC, converts A → B, routes released reserve to the capex sink, vests the creator's retained B. |
| [`AgentControllerFactory`](contracts/AgentControllerFactory.sol) | Holds the controller's creation code so the launchpad stays under the 24 KB limit. Stateless. |
| [`AgentFeeSplitter`](contracts/AgentFeeSplitter.sol) | Fee recipient of a curve. Splits trading fees between the agent's wallet and the platform (default 65 / 35, agent share floored at 50%). |
| [`KycRegistry`](contracts/KycRegistry.sol) | On-chain mirror of DobProtocol's KYC. Consulted only at the crossing; trading A stays permissionless. |
| [`OperatorStake`](contracts/OperatorStake.sol) | Operator bond with cooldown-delayed withdrawals, slashable on proven under-reporting of revenue. |

## Security properties

- **No graduation price cliff.** The AMM is seeded at the curve's terminal price (0.11% drift
  measured on a live testnet run; the E2E script fails above 1%).
- **Solvent conversions.** Pre-graduation, released reserve equals the top-of-curve integral of
  the burned shares, which is the same arithmetic as a sell. Post-graduation, the controller withdraws a
  proportional LP slice and burns its A leg, so the DOBX backing of every circulating A is unchanged.
- **Locked liquidity.** LP tokens are held by the curve, which has no withdrawal path except the
  proportional shrink above.
- **Immutable crossing.** `AgentController` has no owner, proxy, setter or sweep, and
  `bindController` is one-shot, so a live crossing cannot be re-pointed.
- **AMM hardening.** Explicit reserves (no `balanceOf` pricing, no first-depositor attack),
  matched-pair `addLiquidity`, and deadlines on every state-changing trade.
- **Compliance at the edge.** KYC applies only to the A → B conversion.

The key and role model, threat analysis and pre-mainnet separation plan are in
[docs/OPERATIONS.md](docs/OPERATIONS.md).

## Deployments

### Base Sepolia (chain id 84532)

| Contract | Address |
|---|---|
| DOBX | [`0x7E18D1DE113C7F0D02998f61F2715bA5acE5E3c5`](https://sepolia.basescan.org/address/0x7E18D1DE113C7F0D02998f61F2715bA5acE5E3c5) |
| AgentLaunchpad | [`0xA16C303E28F5220196f84fEAa7A1E376f29bd6CA`](https://sepolia.basescan.org/address/0xA16C303E28F5220196f84fEAa7A1E376f29bd6CA) |
| AgentControllerFactory | [`0x8aA347f079B34fD189bD72B5AfeF604F59dDcC3b`](https://sepolia.basescan.org/address/0x8aA347f079B34fD189bD72B5AfeF604F59dDcC3b) |
| KycRegistry | [`0x8c75969aF053a4b4203685b441EDCe9372B077d2`](https://sepolia.basescan.org/address/0x8c75969aF053a4b4203685b441EDCe9372B077d2) |

### Supported networks

| Network | Hardhat name | Chain id |
|---|---|---|
| Base | `base` | 8453 |
| Base Sepolia | `baseSepolia` | 84532 |
| Arbitrum One | `arbitrumOne` | 42161 |
| Arbitrum Sepolia | `arbitrumSepolia` | 421614 |
| Robinhood Chain | `robinhood` | 4663 |

## Getting started

Requirements: Node.js 20+, and [Foundry](https://getfoundry.sh) for the fuzz suite.

```bash
git clone --recurse-submodules https://github.com/opcastil11/conductors-contracts.git
cd conductors-contracts
npm install
npm run compile
```

### Test

```bash
npm test      # Hardhat: lifecycle, graduation, AMM, fee split and the full A→B crossing
forge test    # Foundry: curve fuzzing, AMM and stake invariants
```

End-to-end scripts that run against a live testnet deployment (`scripts/e2e-*.js`) are
described in [docs/STATUS.md](docs/STATUS.md#3-what-is-verified-against-a-real-chain).

### Deploy

```bash
cp .env.example .env          # PRIVATE_KEY, PLATFORM_TREASURY, RPC URLs, explorer API keys
npm run deploy:baseSepolia    # or deploy:arbitrumSepolia, deploy:base, deploy:arbitrum
```

The first deploy on a network mints DOBX. On every later deploy, set `DOBX_ADDRESS` so all curves
share one quote token. Addresses are written to `deployments/<network>.json` (gitignored). See
the full runbook in [docs/DEPLOY.md](docs/DEPLOY.md).

## Documentation

| Document | Contents |
|---|---|
| [TOKENOMICS-V2](docs/TOKENOMICS-V2.md) | Current economic model: the two products, one-way conversion, price floor and creator parameters |
| [STATUS](docs/STATUS.md) | What is deployed and verified on-chain, and what is not built yet |
| [OPERATIONS](docs/OPERATIONS.md) | Roles and keys, threat model, key-separation plan, operational runbook |
| [DEPLOY](docs/DEPLOY.md) | Deployment runbook and per-agent wiring |
| [TOKENOMICS (v1)](docs/TOKENOMICS.md) | Superseded 2026-07-05 model, kept for history |

## Roadmap to mainnet

- [x] Bonding curve, AMM graduation, A→B crossing, KYC gate and fee splitter
- [x] Internal audit fixes, Foundry fuzz/invariant suite, live-testnet E2E runs
- [ ] Integrate DobProtocol's production participation pools (tests currently use a mock B)
- [ ] Key separation: dedicated treasury, delegated KYC attestor, multisig + timelock owner
- [ ] Partial fill of the graduating buy (an oversized buy can overshoot `graduationRaise`)
- [ ] Resolve the open economic items in [TOKENOMICS-V2 §7.3](docs/TOKENOMICS-V2.md)
- [ ] Professional third-party audit

## License

[MIT](LICENSE)
