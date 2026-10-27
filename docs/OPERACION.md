# Operación — llaves, poderes y modelo de amenaza

> **Corte: 09-08-2026.** Complementa a [`DEPLOY.md`](DEPLOY.md) (cómo desplegar) contestando la
> pregunta que ese runbook no contesta: **quién puede hacer qué, y qué pasa si esa llave se
> pierde.** Hoy en Base Sepolia *todos* los roles de §1 son la misma llave. Eso es aceptable en
> testnet y es inaceptable en mainnet; §3 es el plan para separarlos.

---

## 1. Los cinco roles

Son roles, no personas. Un rol es «el conjunto de cosas que una llave puede firmar».

### 1.1 `owner` de la plataforma
Se fija en el constructor: `KycRegistry(deployer, attestor)` y `Launchpad(deployer, dobx, treasury)`
(`scripts/deploy.js:41,55`). Puede:

- `setQuoteToken` — **cambiar el quote token de las curvas nuevas**
- `setPlatformTreasury`, `setKycRegistry`, `setControllerFactory`
- `setAuthorizedLauncher`, `setPublicLaunch` — quién puede lanzar agentes
- `pause` / `unpause` — congelar lanzamientos
- `setAttestor` — **nombrar a quien escribe el KYC**
- `setApproved` en `KycRegistry` (el modificador es `msg.sender == attestor || msg.sender == owner()`)

Es el rol más poderoso del sistema y el que más urge sacar de una EOA.

### 1.2 `platformTreasury`
Recibe el supply íntegro de DOBX al desplegar (`DOBX.deploy(treasury)`), los fees de compra/venta
y el inventario de A que sobra al graduar. **No tiene poderes**, sólo saldo — lo que la hace el
objetivo económico más obvio y el rol que menos excusa tiene para vivir en la misma llave que
el `owner`.

### 1.3 `attestor` del `KycRegistry`
`setApproved` / `setApprovedBatch`. **DobProtocol es la autoridad de KYC** — corre didit.me y el
veredicto se toma en `home.dobprotocol.com`. El registro on-chain es un **espejo**, no una
segunda opinión: por eso el rol está separado del `owner` desde el constructor y se puede
delegar a DobProtocol sin entregar nada más.

Si esta llave se pierde: alguien puede aprobarse a sí mismo para cruzar A→B. Eso rompe el
compliance del cruce (§7.1 de TOKENOMICS-V2), no el dinero — el converter sigue quemando su A.

### 1.4 Firmante gestionado del BFF (`EVM_PRIVATE_KEY`)
Vive en el backend de dobx.pro (repo privado). Firma:
lanzamientos de agentes, `deployController`, la escritura del espejo de KYC, y las transferencias
del faucet. **Vive en un servidor**, o sea que es la llave con mayor superficie de ataque y la
única que un bug de la API puede hacer firmar.

Es también la razón por la que el faucet está acotado por pedido, por ventana de 24 h y con
cooldown por wallet. Sin eso, un `for` vacía la tesorería con la firma
de esta llave y sin explotar nada.

### 1.5 Roles por agente: `creator` y `capexSink`
Ambos **inmutables** en el `AgentController` (`AgentController.sol:65,66`).

- `creator` — beneficiario del B retenido. `releaseRetained()` es permissionless y **siempre**
  paga a esta dirección, así que la llave del creador no hace falta para cobrar: sólo para
  recibir. Perderla es perder el B retenido, no perder el control.
- `capexSink` — **la única salida de quote del controller**. Todo el DOBX liberado por quemas
  sale por acá. No hay función de rescate (comentario en `AgentController.sol:35`): lo que se
  mande por error a este contrato se queda para siempre, y esa es exactamente la propiedad que
  hace que «inmovilizado» sea una garantía y no una promesa.

## 2. Modelo de amenaza — qué se pierde con cada llave

| Llave comprometida | Daño máximo | Mitigación existente |
|---|---|---|
| `owner` | apunta el quote token a un token propio, se auto-nombra attestor, pausa la plataforma | **ninguna** — no hay timelock ni multisig |
| `platformTreasury` | se lleva el supply de DOBX y los fees | ninguna |
| `attestor` | se aprueba a sí mismo y cruza sin KYC | separado del `owner` en el constructor; revocable con `setAttestor` |
| firmante del BFF | drena el faucet, lanza agentes basura, escribe el espejo de KYC | límites del faucet (§1.4); no puede tocar controllers ya desplegados |
| `creator` de un agente | recibe el B retenido de ese agente | vesting con cliff; el pago va a la dirección inmutable |
| `capexSink` de un agente | se lleva el capex liberado de ese agente | ninguna — es un pago, no una custodia |

Lo que **ninguna** llave puede hacer, y esto es el punto del diseño: revertir una conversión,
sacarle B a un converter, cambiar la tasa de conversión después de `activate()` (el denominador
`aSupplyAtActivation` queda fijo para siempre), o mover quote del controller a un destino que no
sea el `capexSink`.

## 3. Plan de separación (pendiente, obligatorio antes de mainnet)

En orden de rendimiento por esfuerzo:

1. **`platformTreasury` a una llave propia.** Es un cambio de una variable de entorno en el
   deploy y de `setPlatformTreasury` en un despliegue existente. Cero código. Saca todo el saldo
   de la llave que además es `owner`.
2. **`attestor` a DobProtocol.** El rol ya está separado; falta acordar la dirección y llamar
   `setAttestor`. A partir de ahí, la única llave que aprueba KYC es la del que hace el KYC.
3. **Firmante del BFF con presupuesto acotado.** Que no sea nunca el `owner`. Su saldo de DOBX
   debería ser sólo el del faucet.
4. **`owner` a un multisig con timelock.** Es el que más cuesta y el que más importa: sin
   timelock, `setQuoteToken` es un ataque de un bloque. Enlaza con §7.3-3 de TOKENOMICS-V2
   (inmutabilidad del controller): las dos preguntas son la misma pregunta —
   *¿qué se puede cambiar después de que alguien ya compró?*

## 4. Runbook operativo

### 4.1 Desplegar la plataforma
Ver [`DEPLOY.md`](DEPLOY.md) §1. Variables mínimas: `PRIVATE_KEY`, `PLATFORM_TREASURY`,
`KYC_ATTESTOR`, `BASE_SEPOLIA_RPC_URL`. Escribe `deployments/baseSepolia.json` — **gitignored**,
así que respaldarlo es parte del deploy, no un extra.

### 4.2 Cablear un agente
`DEPLOY.md` §3. La secuencia obligatoria, porque el orden importa:

```
launch(params)                     → agentId, token A, curve
[el token B tiene que existir ya]  → ver dobx-pro/docs/PUENTE.md §3
deployController(agentId, {participationToken, capexSink, retainedBps,
                           graceSeconds, cliffSeconds, vestSeconds})
transfer(B, controller, totalB)    → el controller custodia TODO el B antes de activar
activate()                         → fotografía convertibleB / retainedB / aSupplyAtActivation
```

`activate()` es irreversible y fija la tasa de conversión. **Transferir B después de activar no
la cambia**: el B que llegue tarde queda en el contrato sin ser alcanzable por nadie.

### 4.3 Cambiar el attestor
```
KycRegistry.setAttestor(nuevaDireccion)   // sólo owner
```
El `owner` conserva `setApproved` como fallback, a propósito: si DobProtocol pierde su llave, el
cruce no se cae.

### 4.4 Si el faucet se está vaciando
Los límites viven en la config del BFF, no en la cadena. Bajarlos es un reinicio del proceso, no un redeploy de contratos.
