# Operations — keys, powers and threat model

> **Cutoff: 2026-08-09.** Complements [`DEPLOY.md`](DEPLOY.md) (how to deploy) by answering the
> question that runbook does not answer: **who can do what, and what happens if that key is
> lost.** Today on Base Sepolia *all* the roles in §1 are the same key. That is acceptable on
> testnet and unacceptable on mainnet; §3 is the plan to separate them.

---

## 1. The five roles

They are roles, not people. A role is "the set of things a key can sign".

### 1.1 Platform `owner`
Set in the constructor: `KycRegistry(deployer, attestor)` and `Launchpad(deployer, dobx, treasury)`
(`scripts/deploy.js:41,55`). It can:

- `setQuoteToken` — **change the quote token of new curves**
- `setPlatformTreasury`, `setKycRegistry`, `setControllerFactory`
- `setAuthorizedLauncher`, `setPublicLaunch` — who can launch agents
- `pause` / `unpause` — freeze launches
- `setAttestor` — **appoint whoever writes the KYC**
- `setApproved` on `KycRegistry` (the modifier is `msg.sender == attestor || msg.sender == owner()`)

It is the most powerful role in the system and the one most urgently in need of being moved off an EOA.

### 1.2 `platformTreasury`
Receives the entire DOBX supply at deployment (`DOBX.deploy(treasury)`), the buy/sell fees
and the leftover A inventory at graduation. **It has no powers**, only a balance — which makes it the
most obvious economic target and the role with the least excuse for living on the same key as
the `owner`.

### 1.3 `KycRegistry` `attestor`
`setApproved` / `setApprovedBatch`. **DobProtocol is the KYC authority** — it runs didit.me and the
verdict is made on `home.dobprotocol.com`. The on-chain registry is a **mirror**, not a
second opinion: that is why the role is separated from the `owner` from the constructor onward and can be
delegated to DobProtocol without handing over anything else.

If this key is lost: someone can approve themselves to cross A→B. That breaks the
compliance of the crossing (§7.1 of TOKENOMICS-V2), not the money — the converter still burns its A.

### 1.4 BFF managed signer (`EVM_PRIVATE_KEY`)
Lives in the dobx.pro backend (private repo). It signs:
agent launches, `deployController`, the KYC mirror writes, and the faucet
transfers. **It lives on a server**, meaning it is the key with the largest attack surface and the
only one that an API bug can make sign.

It is also the reason the faucet is capped per request, per 24 h window and with a
per-wallet cooldown. Without that, a `for` loop drains the treasury with this key's
signature and without exploiting anything.

### 1.5 Per-agent roles: `creator` and `capexSink`
Both **immutable** in the `AgentController` (`AgentController.sol:65,66`).

- `creator` — beneficiary of the retained B. `releaseRetained()` is permissionless and **always**
  pays this address, so the creator's key is not needed to collect: only to
  receive. Losing it means losing the retained B, not losing control.
- `capexSink` — **the controller's only quote outlet**. All DOBX released by burns
  leaves through here. There is no rescue function (comment in `AgentController.sol:35`): whatever is
  sent to this contract by mistake stays there forever, and that is exactly the property that
  makes "locked" a guarantee rather than a promise.

## 2. Threat model — what is lost with each key

| Compromised key | Maximum damage | Existing mitigation |
|---|---|---|
| `owner` | points the quote token to its own token, appoints itself attestor, pauses the platform | **none** — there is no timelock or multisig |
| `platformTreasury` | takes the DOBX supply and the fees | none |
| `attestor` | approves itself and crosses without KYC | separated from the `owner` in the constructor; revocable with `setAttestor` |
| BFF signer | drains the faucet, launches junk agents, writes the KYC mirror | faucet limits (§1.4); cannot touch already-deployed controllers |
| an agent's `creator` | receives that agent's retained B | vesting with cliff; payment goes to the immutable address |
| an agent's `capexSink` | takes that agent's released capex | none — it is a payment, not custody |

What **no** key can do, and this is the point of the design: reverse a conversion,
take B out of a converter, change the conversion rate after `activate()` (the denominator
`aSupplyAtActivation` is fixed forever), or move quote from the controller to a destination other
than the `capexSink`.

## 3. Separation plan (pending, mandatory before mainnet)

In order of return on effort:

1. **`platformTreasury` to its own key.** It is a change of one environment variable in the
   deploy and of `setPlatformTreasury` on an existing deployment. Zero code. It moves the entire balance
   off the key that is also `owner`.
2. **`attestor` to DobProtocol.** The role is already separated; what remains is agreeing on the address and calling
   `setAttestor`. From then on, the only key that approves KYC is that of whoever performs the KYC.
3. **BFF signer with a capped budget.** It must never be the `owner`. Its DOBX balance
   should be only the faucet's.
4. **`owner` to a multisig with timelock.** It is the costliest and the one that matters most: without a
   timelock, `setQuoteToken` is a one-block attack. Ties in with §7.3-3 of TOKENOMICS-V2
   (controller immutability): the two questions are the same question —
   *what can be changed after someone has already bought?*

## 4. Operational runbook

### 4.1 Deploy the platform
See [`DEPLOY.md`](DEPLOY.md) §1. Minimum variables: `PRIVATE_KEY`, `PLATFORM_TREASURY`,
`KYC_ATTESTOR`, `BASE_SEPOLIA_RPC_URL`. Writes `deployments/baseSepolia.json` — **gitignored**,
so backing it up is part of the deploy, not an extra.

### 4.2 Wire up an agent
`DEPLOY.md` §3. The mandatory sequence, because order matters:

```
launch(params)                     → agentId, token A, curve
[token B must already exist]       → see dobx-pro/docs/PUENTE.md §3 (private dobx-pro repo)
deployController(agentId, {participationToken, capexSink, retainedBps,
                           graceSeconds, cliffSeconds, vestSeconds})
transfer(B, controller, totalB)    → the controller holds ALL of B before activating
activate()                         → snapshots convertibleB / retainedB / aSupplyAtActivation
```

`activate()` is irreversible and fixes the conversion rate. **Transferring B after activating does not
change it**: B that arrives late stays in the contract, unreachable by anyone.

### 4.3 Change the attestor
```
KycRegistry.setAttestor(nuevaDireccion)   // owner only
```
The `owner` keeps `setApproved` as a fallback, on purpose: if DobProtocol loses its key, the
crossing does not go down.

### 4.4 If the faucet is being drained
The limits live in the BFF config, not on-chain. Lowering them is a process restart, not a contract redeploy.
