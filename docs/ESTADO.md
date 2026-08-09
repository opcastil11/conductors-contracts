# Estado de construcción — qué existe, dónde, y verificado cómo

> **Corte: 09-08-2026.** Este documento existe porque [`TOKENOMICS-V2.md`](TOKENOMICS-V2.md) es
> una *derivación* — dice qué debe pasar — y hasta ahora no había ningún lugar que dijera qué
> **pasa**. Cuando los dos se contradigan, gana éste: la fuente de verdad de este archivo son
> direcciones en Base Sepolia y respuestas de `https://dobx.pro/api`, no el diseño.
>
> Regla de escritura: **nada entra acá sin una dirección, un endpoint o un script que lo
> reproduzca.** «Está implementado» sin eso va en §4 (lo que falta), no en §1.

---

## 1. Contratos desplegados — Base Sepolia (chainId 84532)

`deployments/baseSepolia.json` (el directorio `deployments/` está gitignored: estas direcciones
sólo viven ahí, en el `.env` de producción y en esta tabla).

| Contrato | Dirección | Rol |
|---|---|---|
| `DOBX` | `0x7E18D1DE113C7F0D02998f61F2715bA5acE5E3c5` | quote token de todas las curvas (18 dp) |
| `AgentLaunchpad` | `0xA16C303E28F5220196f84fEAa7A1E376f29bd6CA` | `launch()` + `deployController()` |
| `AgentControllerFactory` | `0x8aA347f079B34fD189bD72B5AfeF604F59dDcC3b` | despliega un `AgentController` por agente |
| `KycRegistry` | `0x8c75969aF053a4b4203685b441EDCe9372B077d2` | espejo on-chain del KYC de DobProtocol |
| `platformTreasury` | `0x305DaB055730E0b3AB193051e67ADa3E9BC59142` | supply de DOBX + fees + inventario A sobrante |

Fuentes de cada contrato en `contracts/`: `DOBX.sol`, `AgentLaunchpad.sol`,
`AgentControllerFactory.sol`, `AgentController.sol`, `AgentBondingCurve.sol`, `AgentAMM.sol`,
`AgentShareToken.sol`, `KycRegistry.sol`, `OperatorStake.sol`.

**Ya no existen** (borrados en `ab99832`, según §8 de TOKENOMICS-V2): `AgentConverter`,
`AgentBuyback`, `AgentTreasury`, `TokenomicsFactory`. Nada del modelo firmado de 2026-07-05
sigue en el árbol.

## 2. Agentes vivos con el cruce A→B montado

Los dos salieron de corridas E2E reales, no de seeds. Se dejan en producción a propósito: son
la única demostración viva del cruce, incluida la divergencia entre la tasa *anunciada* y la
*pagada*. Borrarlos es la tarea #7 y es decisión del usuario.

| Agente | `AgentController` | Retenido | Tasa pagada | Gracia |
|---|---|---|---|---|
| `agt_b93f715928fb43baae96` «E2E Cruce» | `0x2AF6794289D75c88a89775aA827DFba0dB57CB33` | 30 % | 0,7 B por A | 0 s |
| `agt_fab6265bbe9546409a23` «E2E Ratio» | `0x5C7C185Cc97d1330bdC75D2F4f0c506619e665A6` | 30 % | 0,7 B por A | 0 s |

Ambos: pool de 100 000 USD, 36 meses, descuento 15 %, piso de A = 0,0824 USD.
Verificable sin credenciales: `curl -s https://dobx.pro/api/agents`.

## 3. Lo que está verificado contra una cadena real

Tres scripts, todos contra Base Sepolia viva — no Hardhat local, no forks. Cada uno lanza su
propio agente chico para no gastar tesorería observando una propiedad aritmética.

### 3.1 `scripts/e2e-crossing.js` — el cruce
Compra A en la curva, adjunta un controller, activa, convierte. Verifica que A se **quema**, que
el converter recibe B, que **no** recibe DOBX, y que la reserva que respaldaba ese A sale hacia
el `capexSink`. La tasa observada es `bOut = aIn × convertibleB / aSupplyAtActivation` — que es
la que hay que mostrar en la UI, no `1 − retainedBps`: divergen apenas el B emitido no es 1:1
contra el supply de A.

### 3.2 `scripts/e2e-grace.js` — la gracia sí cierra la puerta
Las dos corridas anteriores usaban `graceDays 0`, o sea que el reloj de gracia nunca se había
ejercido contra timestamps de bloque reales. El script activa con gracia corta, comprueba que
`convert()` **revierte** con un mensaje que contiene «grace», espera el reloj, y comprueba que
la *misma llamada* al *mismo controller* ahora pasa. Resultado: 0,7 B por A con 30 % retenido.

> Detalle que el script documenta en el código: `convert()` chequea `activated → grace →
> wholeShares > 0 → kyc`, en ese orden. La primera mitad es grace-only aunque la dirección no
> esté aprobada; la segunda mitad necesita el espejo escrito o revertiría por KYC y **parecería**
> que la gracia nunca venció.

### 3.3 `scripts/e2e-graduation.js` — graduación sin salto de precio
La afirmación del header de `AgentBondingCurve` es «no graduation price cliff». Una curva que
gradúa hacia un AMM con precio distinto al terminal le regala el hueco al primer trader
post-graduación, así que lo que se asserta es **continuidad de precio**, no que `graduated`
haya cambiado a `true`. Medido: **0,109 % de drift** entre el precio terminal de la curva y
`quoteReserve / shareReserve` del AMM sembrado. El script falla si supera 1 %.

### 3.4 Guardas que quedaron en los scripts
- `settled(() => provider.getCode(addr), c => c !== "0x")` — el RPC público de Base Sepolia
  contesta `0x` para un contrato recién minado; sin esto toda llamada falla con `BAD_DATA`.
- El inventario A sobrante se reporta restando lo comprado, porque en este despliegue
  `platformTreasury` **es** el firmante y su balance incluye el A que el script acaba de comprar.

## 4. Lo que existe en el BFF / web (`dobx-pro`, commit `52b8d2f`)

| Pieza | Dónde | Estado |
|---|---|---|
| KYC leído de DobProtocol | `services/dob.client.js#getKycStatus`, `routes/auth.routes.js` `GET /kyc/status`, `POST /kyc/sync` | ✅ vivo (401 sin JWT, verificado en prod) |
| Espejo on-chain del KYC | `services/evm-launch.client.js#setKycApproved` → `KycRegistry.setApproved` | ✅ vivo |
| Faucet acotado | `FAUCET_MAX=500`, ventana 24 h `2000`, cooldown 60 s; tabla `faucet_grants` | ✅ vivo (429 verificado en prod) |
| 400 en direcciones malformadas | `lib/evm-address.js` (`evmAddress` / `looksEvm` / `maybeEvmAddress`) | ✅ vivo — antes eran 500 desde dentro de ethers |
| Vesting del B retenido | `GET /agents/:id/vesting`, `POST /agents/:id/vesting/release/prepare`, `components/VestingCard.tsx` | ✅ vivo |

`releaseRetained()` es **permissionless** y siempre paga al `creator` inmutable del controller,
así que la tarjeta no necesita chequeo de propiedad: un extraño que firme está regalando gas.

## 5. Lo que NO está construido ni probado

Esto es la lista honesta. Nada de acá tiene dirección ni endpoint.

| # | Falta | Por qué importa |
|---|---|---|
| 1 | **El pool real de DobProtocol como producto B.** Todos los E2E usan `MockParticipation`. | El cruce está probado contra un ERC-20 de juguete. Ver [`dobx-pro/docs/PUENTE.md`](../../dobx-pro/docs/PUENTE.md): el stack V2 en Base **ya existe**, falta cablearlo. |
| 2 | **El circuito de ingreso x402 → pool → distribución.** | Sin esto B no paga nada y el piso de A es teoría. DOBI estaba caído en las corridas. |
| 3 | **KYC end-to-end con un usuario realmente aprobado.** | Está probado el 401 y el espejo; falta el camino feliz completo con un JWT aprobado por didit.me. |
| 4 | **Mainnet.** Todo vive en Base Sepolia. | — |
| 5 | **Separación de llaves** (hoy una sola llave es deployer, owner, tesorería, attestor y firmante del BFF). | Ver [`OPERACION.md`](OPERACION.md) §2 — es el riesgo operativo más grande. |
| 6 | **Inmutabilidad del `AgentController`** — decidir y dejarlo escrito. | §7.3-3 de TOKENOMICS-V2: si es actualizable sin timelock, reabre todo lo que cierra. |
| 7 | **Emisión y distribución de DOBX** (supply, quién lo tiene al arrancar, cómo entra alguien que sólo tiene USDC). | §7.3-4. |
| 8 | **Calibración numérica descuento ↔ curva** para un agente real. | §7.3-5: sin esto §3.4 de TOKENOMICS-V2 es teoría. |
| 9 | **El capex liberado queda en DOBX** y financiar un activo físico obliga a venderlo. | §4.2 — el pendiente que TOKENOMICS-V2 marca como el más urgente, y sigue abierto. |

## 6. Cómo reproducir

```bash
cd dobx-contracts                       # .env con PRIVATE_KEY financiada en Base Sepolia
npx hardhat run scripts/e2e-crossing.js   --network baseSepolia
npx hardhat run scripts/e2e-grace.js      --network baseSepolia   # GRACE_SECONDS=180 por defecto
npx hardhat run scripts/e2e-graduation.js --network baseSepolia   # SUPPLY/GRAD_RAISE/SHARES
```

Cada script lanza su propio agente: no tocan los de §2 ni la tesorería de producción más allá
del DOBX que gastan comprando en su propia curva.
