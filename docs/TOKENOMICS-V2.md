# Tokenomics v2 — modelo one-way A→B sobre pools de *future revenue*

> **Estado: VIGENTE. 08-08-2026.** Reemplaza a [`TOKENOMICS.md`](TOKENOMICS.md) (firmado
> 2026-07-05), que queda como registro histórico del modelo con buyback/converter/tesorería.
> Este documento es la derivación completa; la versión navegable y con estado de construcción
> por pieza vive en `dobx.pro/arquitectura` (`dobx-pro/apps/web/src/pages/ArchitecturePage.tsx`).
>
> Notación:
> **✅ verificado** = confirmado leyendo código, con referencia · **▶ decidido** = decisión
> tomada, sin construir todavía · **❓ abierto** = falta decidir.
>
> **Actualización 30-09-2026 — B es un pool abierto, no un crédito.** Decisión de producto: B deja
> de modelarse como factoring (monto pedido, tasa de descuento, plazo, amortización hasta cero).
> B es un pool **free to join** y sin plazo: cuando termina la etapa A se entra **cruzando A**
> (un solo sentido), lo que ganan los activos del agente se deposita en el pool y se reparte
> pro-rata, y se sale **vendiendo B** en el marketplace. Sin retorno prometido. Los contratos no
> cambian: los números de factoring nunca llegaron a la cadena (vivían en el BFF y en
> `pool_data`). Las secciones §2-B, §3.3, §3.4 y §6 quedan reescritas para este modelo.
>
> **Actualización 09-08-2026.** La línea original de este banner decía «nada de este modelo está
> construido aún». **Ya no es cierta y por eso se retira**: los contratos están desplegados en
> Base Sepolia y el cruce, la gracia y la graduación están verificados contra cadena viva. Este
> documento sigue siendo la *derivación* — qué debe pasar. Lo que **pasa** vive en
> [`ESTADO.md`](ESTADO.md), y cuando los dos se contradigan gana ESTADO. Las llaves y sus
> poderes están en [`OPERACION.md`](OPERACION.md).
>
> Dos correcciones de fondo, ambas derivadas de leer el código desplegado de DobProtocol:
> **(a)** el «puente» A↔B no existe como problema — DobProtocol ya emite participaciones en Base
> mainnet, ver [`dobx-pro/docs/PUENTE.md`](../../dobx-pro/docs/PUENTE.md); **(b)** el admin del
> pool **no puede** ser el `AgentController` (§3.2 quedó corregido más abajo).

---

## 0. Qué cambia respecto al modelo firmado

El modelo firmado tenía dos productos que se vendían por separado, se conectaban con un flujo
"vendé A por USDC, comprá B en el marketplace" (§5 de `TOKENOMICS.md`), y se sostenían con un
buyback financiado por el revenue. Este modelo lo reemplaza por **un solo camino de entrada (A),
una conversión one-way A→B, y el pool de future revenue de DobProtocol como único destino del
ingreso.**

| Componente | Modelo firmado | Modelo vigente |
|---|---|---|
| Quote token de la curva | USDC | **DOBX** — token de plataforma, modelo Virtuals |
| Mercado de A | curva → AMM | **igual**, pero el par es A/DOBX |
| Mercado de B | marketplace DobProtocol, precio propio en USDC | **primaria: solo con A**; salida: exit liquidity / marketplace en USDC |
| Puente A→B | vender A por USDC, comprar B (2 pasos, no atómico, fee 0,5–1%) | **conversión one-way 1:1, mismo cap, con quema de A** |
| Admin del pool | wallet del operador | **`AgentController`** — un contrato, no una wallet |
| `AgentConverter` | ✅ construido | **se elimina** |
| `AgentBuyback` + TWAP + keeper | ✅ construido | **se elimina** |
| `AgentTreasury` (reserva B, backstop) | ✅ construido | **se elimina** |
| `TokenomicsFactory` | ✅ construido | **se elimina** |
| Split del revenue | operador% / buyback% (10–50%) / distribución% | **100% al pool**; todo corte ocurre dentro de la cap table |
| `operator_split_bps` (dobx BFF) | 30% off-the-top | **se elimina** |
| Ganancia del operador | split off-the-top + tesorería | **`participation_to_sale` retenido**, custodiado por el controller |
| Piso de A | arbitraje indirecto vía dos mercados | **`P_A ≥ P_B` mecánico**, con término de FX; `P_B` es precio de mercado |
| Financiamiento del capex | sin definir (conflicto con la reserva de la curva) | **liberación de reserva al quemar A** — ❓ con una arista abierta (§4.2) |
| Estatus legal de A | "A no está soldado a B" | **gate de KYC en el cruce A→B, dentro de DobProtocol** |

Superficie de contratos que desaparece: converter, buyback, tesorería, factory, ejecución TWAP,
cron de keeper, tope por época, y toda la superficie MEV asociada. Aparece: `AgentController` y
el token `DOBX`.

---

## 1. El modelo completo

```
        DOBX
          │  compra en la curva (precio sube $0,05 → terminal)
          ▼
    ┌───────────┐   conversión one-way 1:1, mismo cap
    │  TOKEN A  │───────────────────────────────────────────┐
    │ perpetuo  │   · el A pagado se quema/inmoviliza       │
    │ especulat.│   · libera su parte de la reserva → capex │
    └───────────┘                                            ▼
          ▲                                        ┌──────────────────┐
          │ vender en el AMM (única salida de A)   │     TOKEN B      │
          ▼                                        │   pool abierto   │
        DOBX                                       │ sin plazo; sales │
                                                   │  vendiendo B     │
                                                   └──────────────────┘
                                                        │         │
   x402 (DOBI) ──── 100% del ingreso ───────────────────┘         │
                    aterriza en el pool                            │
                                                                   ▼
                                              distribución USDC según calendario
                                              (arranca tras el período de gracia)
                                                                   │
                                                                   ▼
                                              salida: exit liquidity (LPs con USDC)
                                                      o marketplace secundario
```

Dos mercados con precios distintos, un piso que los conecta, y una migración de uno al otro que
además es el mecanismo de financiamiento.

---

## 2. Los dos productos

### A — token del agente (perpetuo, especulativo)

- ERC-20 de supply fijo, curva de bonding que gradúa a AMM. Ya construido
  (`AgentShareToken`, `AgentBondingCurve`, `AgentAMM`).
- **Cotiza contra DOBX, no contra USDC.** ▶ Modelo Virtuals: el token de la plataforma es la
  moneda de todos los agentes, así que cada lanzamiento y cada compra es un sink de DOBX.
- No recibe distribuciones. Su vínculo con el ingreso es **el derecho a convertir**.
- Su mercado es permissionless: el gate de KYC está en el cruce hacia B, no acá (§7.1).
- Vive en el mercado de la atención: su ventana de valor especulativo es corta por naturaleza, y
  el diseño la protege con el período de gracia (§6).

**✅ verificado — el cambio de quote token no exige reescribir contratos:**
`AgentLaunchpad.setQuoteToken()` es `onlyOwner` y emite `QuoteTokenUpdated`
(`AgentLaunchpad.sol:87`). Pero `AgentBondingCurve.quoteToken` es `immutable`
(`AgentBondingCurve.sol:32`): cada curva fija su quote al desplegarse.

> **Consecuencia:** los agentes ya lanzados quedan atados a MockUSDC para siempre — MSOL
> incluido. Migrar a DOBX significa **relanzar**, no reconfigurar.

### B — participación en un pool abierto de DobProtocol

B es la participación en el pool del agente. **No es un crédito**: no hay monto pedido, tasa de
descuento ni plazo, y el pool no se cierra cuando «termina de pagar» — paga mientras el agente
opere y gane.

- **Entrada:** solo cruzando A, cuando termina la etapa A y vence la gracia. El pool no emite B
  a la venta.
- **Ingreso:** lo que ganan los activos (x402) se deposita en el pool y se reparte pro-rata.
  Cobro pull-based: el tenedor **reclama**, nadie le transfiere.
- **Salida:** vender B en el marketplace secundario (liquida en USDC).
- Supply fijo, cap table por porcentajes (`submitInit({ participants: [{address, percentage}] })`).

El pool de DobProtocol trae campos de crédito (`estimated_apr`, `total_sale_pool_asked`,
`distribution_dates`/`duration`; ver `Dober-MVP/back-end/services/poolUtils.service.js:341`).
Conductors no los usa: en Base no llegan a la cadena y en la ruta Stellar se mandan en 0 / vacíos.

---

## 3. La conversión A→B

### 3.1 Mecánica

**✅ verificado — DobProtocol acepta un token de pago arbitrario, independiente del token de distribución:**

| Vía | Referencia | Qué acepta |
|---|---|---|
| Crowdfunding Stellar | `stellar.service.js:1089` — `init(admin, payment_token, price_per_share, soft_cap, hard_cap, deadline, payout_mode)` | cualquier SAC |
| Sale EVM | `evm-pool.service.js:322` — `prepareCreateSale({participationToken, paymentToken, price})` | cualquier ERC-20 (`0x0` ⇒ ETH) |
| Marketplace secundario | `payment_token_address` **por listing** (`stellar-marketplace.service.js`) | lo que elija el vendedor |
| Exit liquidity | `payment_token_address` **por oferta de LP** (`stellar-exit-liquidity.service.js`) | lo que elija el LP |

Distribución aparte: `prepareDistribute({ tokenAddress })` — va en **USDC**.

▶ **El diseño:**
- Campaña de crowdfunding del pool con **`payment_token = A`**, `price_per_share` tal que
  **1 A = 1 B**, y `total_shares(B) = total_supply(A)` (mismo cap).
- **`payoutMode = 0` (Escrow)** — ✅ verificado en `stellar.service.js:1099`: modo 0 manda los
  fondos al **splitter** (el contrato del pool) en `activate()`; modo 1 (`DirectToOwner`) los
  manda a la **wallet del admin**. Modo 0 es lo que impide que el operador se quede con el A
  recaudado. Hoy `dobx-pro/apps/api/src/services/tokenize.service.js` no pasa este parámetro.
- El A que entra al splitter **queda permanentemente inmovilizado**.

**Es one-way.** No existe B→A. Quien convirtió, convirtió.

### 3.2 `AgentController` — por qué «quemado» es una garantía y no una promesa

El escrow deja el A en el splitter, pero eso solo sirve si nadie puede sacarlo de ahí. La
pregunta abierta era si `soro_splitter` expone un barrido de admin (en el repo solo está el
`.wasm` compilado, `stellar.service.js:74`).

▶ **La decisión evita tener que responderla:** el admin del pool **deja de ser una wallet** y
pasa a ser un contrato, el `AgentController`, que no expone ninguna función para mover esos
fondos. Si la llamada no existe en el único address que podría hacerla, da igual que el splitter
la tenga.

El mismo contrato absorbe la otra regla que hacía falta:

- **El A convertido queda inmovilizado** — sin superficie de retiro, «inmovilizado» y «quemado»
  son funcionalmente lo mismo.
- **El B retenido por el creador vive adentro**, con su cliff y su calendario aplicados por
  código (§5.3).

> ❓ **Abierto y crítico: la garantía vale lo que valga su llave de upgrade.** Un controller
> actualizable sin timelock reabre todo lo que cierra — quien pueda cambiarlo puede agregarle el
> barrido después. Tiene que ser **inmutable**, o su llave estar quemada o detrás de un timelock
> lo bastante largo como para que el mercado reaccione.

> ⛔ **Corrección 09-08-2026 — «el admin del pool es el controller» no es implementable.**
> Contra el `PoolMasterV2` que DobProtocol tiene desplegado en Base, `createTreasuryPool` hace
> dueño del pool a `users[0]`, y en la lógica v2 (auditoría 2026-08, hallazgo B-1)
> `createDistribution` es **owner-only**. `AgentController` no tiene passthrough de llamadas, así
> que ponerlo de dueño dejaría al pool **sin nadie capaz de repartir**.
>
> La separación correcta: **dueño del pool** = quien opera las distribuciones (una wallet);
> **`AgentController`** = custodio del B y único emisor de la razón de conversión. Lo que este
> §3.2 quería garantizar **no se pierde** — sigue siendo cierto que nadie puede sacarle B a un
> converter, cambiar la razón después de `activate()`, ni mover quote a un destino distinto del
> `capexSink`. Lo que se cae es la frase «el admin del pool es un contrato, no una wallet».
> Derivación completa en [`dobx-pro/docs/PUENTE.md`](../../dobx-pro/docs/PUENTE.md) §4.

### 3.3 Relación de precios

El arbitraje corre en un solo sentido: si `P_B > P_A`, comprás A, convertís, vendés B — eso
empuja `P_A` hacia arriba. Si `P_B < P_A` no hay nada que hacer. Por lo tanto:

```
P_A ≥ P_B          →          A = B + prima especulativa
```

- **A tiene piso.** El mercado de renta le pone un suelo al mercado especulativo.
- **A puede cotizar arriba sin límite.** La prima es la especulación, y no se arbitra.
- **El piso es de mercado.** `P_B` es lo que el marketplace paga por B, que sigue a lo que el
  agente gana. No hay una cifra «adeudada» que lo fije ni lo haga decaer; Conductors muestra el
  ratio de cruce, no un piso calculado.

**Con DOBX como quote, el piso lleva un término de tipo de cambio.** A cotiza en DOBX y B
distribuye en USDC, y la conversión es 1:1 en **unidades**, no en valor:

```
P_A(DOBX) × DOBX/USDC  ≥  P_B(USDC)
```

> ❓ Consecuencia a asumir o mitigar: **si DOBX cae, el piso de A medido en DOBX sube.** El suelo
> sigue existiendo, pero la volatilidad de DOBX se propaga a todos los mercados de agentes a la
> vez.

**Y el arbitraje solo lo ejecuta quien pasa el KYC** (§7.1). Para el resto del mercado, A flota
sin piso. Es el precio de resolver lo legal en el cruce, y está asumido.

### 3.4 Convertir tiene que convenir

Cruzar entrega algo que vale `P_A` por algo que vale `ratio × P_B`. Quien compró A arriba de la
curva puede quedar sin incentivo a cruzar mientras B no cotice por encima. El precio terminal de
la curva es el dial del creador que fija ese techo (`agents.terminal_price`, default 0,25 DOBX).
Como B ya no promete una producción total, **no hay comprobación a priori**: la decide el mercado
de B. (La versión anterior de esta sección ataba el precio terminal a `total_produccion / shares`;
ese término ya no existe.)

---

## 4. El financiamiento: el capex sale de las conversiones

### 4.1 El argumento

**Una bonding curve no es un levantamiento de capital, es un market maker con balance.** Lo que
entra cuando alguien compra A no es plata recaudada: es la **reserva** con la que la curva le
paga a quien después venda. Es un pasivo. `AgentBondingCurve` tiene reservas explícitas.

Si el operador gasta esa reserva en el activo, queda un sistema de reserva fraccionaria que
funciona solo mientras entre más de lo que sale:

```
curva vende 200k A                        → reserva = 30k DOBX
operador gasta 25k en el cargador         → reserva = 5k DOBX
tenedores de 100k A salen                 → necesitan 15k DOBX → la curva quiebra
```

**La conversión resuelve esto exactamente.** Cada A convertido a B se retira permanentemente del
lado vendedor de la curva; su parte de la reserva deja de ser un pasivo de recompra. De ahí sale
la regla:

> ▶ **El capex no se financia con el raise. Se financia con las conversiones.** La reserva queda
> 100% respaldada para todo el A no convertido. Al quemar un A, la curva libera lo que le habría
> pagado por recomprarlo, y eso va al activo.

El incentivo queda alineado solo: **para financiar el activo, el operador tiene que hacer
atractiva la conversión** — es decir, tiene que hacer que el ingreso sea real. No hay forma de
sacar el dinero sin que alguien renuncie voluntariamente a su derecho de reventa.

### 4.2 La arista que abre DOBX

❓ **Al mover la curva a DOBX, lo que libera la quema deja de ser USDC.** Convertirlo en un
activo físico exige **venderlo por USDC** — o sea, presión de venta sobre el propio token de la
plataforma justo cuando los agentes empiezan a funcionar, que es exactamente cuando no la
querés. Es la contracara del sink: **DOBX sube al lanzar agentes y baja al financiarlos.**

Opciones sobre la mesa, ninguna elegida:
1. Venta en mercado, asumiendo el impacto.
2. Un fondo de USDC de la plataforma que compre el DOBX liberado.
3. Que el capex lo adelante el operador contra su B retenido.

**Es el pendiente más urgente del modelo.**

### 4.3 Criterio de encaje

El período de gracia (§6) está diseñado para que **nadie convierta durante el primer año**. Eso
significa **cero financiamiento de capex en el año 1**.

▶ **Por lo tanto este modelo encaja con activos ya financiados**, no con levantamientos para
capex nuevo. Ese camino ya existe en el código: `tokenize.service.register({ linkedPools })`
enlaza pools de DobProtocol ya tokenizados que el agente pasa a operar. En ese caso el año de
gracia es el operador recuperando su capex antes de empezar a repartir — estructura estándar de
project finance.

---

## 5. La cascada de ingresos

### 5.1 Todo el ingreso aterriza en el pool

▶ **`operator_split_bps` se elimina.** Hoy `dobx-pro/apps/api/src/config.js` descuenta 30% del
gross **antes** de que el dinero llegue al pool. Eso rompe dos cosas:

1. **La auditoría.** Si la address del pool es el punto de auditoría — que es la razón por la que
   en la práctica opex y ganancia se mezclan ahí — entonces un corte aguas arriba deja el rastro
   on-chain incompleto.
2. **El APR publicado.** DobProtocol calcula el retorno con los números del pool
   (`poolUtils.service.js:341`), que no saben del descuento previo. El pool promete una
   producción total que nunca va a llegar completa.

> **Regla: el 100% del ingreso x402 aterriza en la address del pool. Todos los cortes ocurren
> dentro de la cap table.**

### 5.2 La ganancia del operador vive en `participation_to_sale`

**✅ verificado:** `pool_data.participation_to_sale` es literalmente "percentage of pool for
sale" y `calculatedApr` ya lo usa (`poolUtils.service.js:344`). No es una feature nueva — es un
campo que dobx hoy no expone: `tokenize.service.completeInit` mete
`participants: [{ operator, 100 }]` y nunca setea `participation_to_sale`.

▶ **En el wizard de tokenización se le pregunta al creador qué % del future revenue retiene.**
Ese % cubre su opex y su ganancia, mezclados.

**Consecuencia que hay que declarar:** el operador absorbe la volatilidad del opex, no los
inversionistas. Es una estructura de arriendo bruto. Es defendible y más simple, pero exige
declararlo explícitamente ("el operador corre con el opex").

❓ El piso de retención realista por tipo de activo (cargador / solar / vending) **se difiere**:
no es un problema hoy y se calibra con datos de operación reales en vez de adivinarlo ahora. El
riesgo a vigilar es que si el opex se come la retención de forma persistente, el operador
abandona el activo y el pool muere.

### 5.3 Lockup del B retenido

▶ **Resuelto por el `AgentController` (§3.2).** El B retenido lo custodia el controller, que
aplica el cliff y el calendario por código, así que el creador no puede listarlo en el
marketplace secundario antes que los inversionistas.

(Exit liquidity **no** era el vector: ahí el LP deposita USDC y *compra* shares con
`discount_bps` — `stellar-exit-liquidity.service.js:71`; el que sale es quien paga el descuento.)

---

## 6. Los parámetros del creador

El diseño no fija valores: define **un espacio que el creador navega**. Todos están en el wizard
de dobx-pro (paso «Fase A → B»). No hay monto, tasa ni plazo: B es un pool abierto.

| # | Parámetro | Dónde vive |
|---|---|---|
| 1 | Precio terminal de la curva | slope de `AgentBondingCurve` |
| 2 | **Gracia antes de abrir el cruce** | `AgentController.graceEndsAt` |
| 3 | % de B retenido por el creador | `AgentController` (`retainedBps`) |
| 4 | Cliff / vesting del retenido | `AgentController` |

### 6.1 El período de gracia — el separador de fases

Es la pieza que hace que los dos productos no se canibalicen:

- **Durante la gracia (p. ej. 12 meses):** B no paga nada. Convertir significa entregar un token
  líquido por un papel que todavía no rinde → **nadie convierte**. A conserva su float completo y
  tiene la ventana entera del mercado de atención, que es donde vive su valor y que decae rápido
  por naturaleza.
- **Al terminar la gracia:** convertir pasa a ser racional y A empieza a secarse hacia B.

El piso `P_A ≥ ratio × P_B` **existe desde el día uno** aunque nadie pueda cobrar todavía.

### 6.2 Los acoplamientos (esto es lo que el wizard tiene que mostrar)

- **Precio terminal (#1) ↔ incentivo a cruzar.** Un terminal alto deja a los últimos compradores
  de A sin razón para cruzar mientras B no cotice arriba (§3.4).
- **Gracia (#2) ↔ retención (#3).** Más gracia = más protagonismo de A = el creador puede
  permitirse retener menos de B. Y al revés.
- **Retención (#3) ↔ piso de A.** Cada punto retenido baja el piso proporcionalmente: con 30%
  retenido, el piso de A es el 70% del que sería. **La retención del creador y la fuerza del
  vínculo entre los dos mercados son la misma perilla vista desde dos lados.**

### 6.3 Presets

▶ Perfiles de referencia (el wizard hoy expone los diales sueltos, con validaciones):

| | **Perfil atención** | **Perfil renta** | **Balanceado** |
|---|---|---|---|
| Gracia | larga (18–24m) | corta (0–6m) | 12m |
| Retención | alta | baja | media |
| Curva | terminal alto | terminal bajo | medio |
| Resultado | A protagonista, B tardío y chico | B protagonista, A se seca rápido | migración gradual |

---

## 7. Decisiones tomadas y lo que queda abierto

### 7.1 La decisión legal — resuelta en el cruce

`TOKENOMICS.md` §7 sostenía que A estaba limpio **precisamente porque no estaba soldado a B**, y
la objeción natural a este modelo era que el vínculo 1:1 convierte a A en la única vía de acceso
a un instrumento que distribuye flujo de caja — o sea, bajo Howey, probablemente un security.

▶ **Decisión: el gate está en el cruce, no en la curva.** A es un token de plataforma, como en
Virtuals, y su mercado es permissionless. La conversión A→B **ocurre únicamente dentro de
DobProtocol**, así que quien cruza pasa por el KYC y el compliance que ahí ya están construidos
para B. El instrumento que distribuye flujo de caja nunca sale de un entorno regulado, y la
curva no arrastra esa carga.

**Deja de ser bloqueante.** El residuo es económico, no legal, y está asumido: el arbitraje que
sostiene `P_A ≥ P_B` solo existe para los usuarios que pueden cruzar; para el resto, A flota sin
piso (§3.3).

### 7.2 Estado de las cinco preguntas que estaban abiertas

| # | Tema | Resolución |
|---|---|---|
| 1 | ¿`soro_splitter` tiene barrido de admin? | ▶ **Deja de importar.** El admin es el `AgentController`, no una wallet (§3.2). |
| 2 | Calibración descuento ↔ curva | ▶ **Modelo Virtuals con DOBX como quote token** (§2). La calibración numérica sigue pendiente (#3 abajo). |
| 3 | Piso de retención por tipo de activo | ▶ **Diferido.** No es un problema hoy; se calibra con datos reales (§5.2). |
| 4 | Vesting del B retenido | ▶ **Resuelto por el `AgentController`** (§5.3). |
| 5 | Estatus legal de A | ▶ **Resuelto: KYC en el cruce** (§7.1). |

### 7.3 Lo que estas decisiones dejan abierto

Consecuencias, no objeciones: cada una nace de una de las resoluciones de arriba.

| # | Tema | Sección | Tipo |
|---|---|---|---|
| 1 | **El capex liberado queda en DOBX** y financiar un activo físico obliga a venderlo. | §4.2 | ❓ decidir — el más urgente |
| 2 | **El piso de A queda expuesto al FX de DOBX**; su volatilidad se propaga a todos los agentes. | §3.3 | ❓ decidir |
| 3 | **Inmutabilidad del `AgentController`**: si es actualizable sin timelock, reabre todo lo que cierra. | §3.2 | ❓ decidir |
| 4 | **Emisión y distribución de DOBX**: supply, quién lo tiene al arrancar, cómo llega el comprador que solo tiene USDC. | §2 | ❓ decidir |
| 5 | **Calibración del precio terminal** contra lo que B cotice en un agente real (§3.4). | §3.4 | ❓ decidir |
| 6 | **El arbitraje solo existe para quien pasa el KYC.** | §3.3 | asumido |
| 7 | Atestación del ingreso (`OperatorStake` ya construido, la atestación misma no). | — | heredado de `TOKENOMICS.md` §6 |
| 8 | **Granularidad de B.** El `ParticipationToken` de DobProtocol tiene `decimals() == 0` y el límite de shares es 10 000 000. Si el pool se crea con porcentajes 1–100, toda conversión normal revierte con `"dust"`. | PUENTE §3.3 | ❓ decidir antes de cablear |
| 9 | **Separación dueño-del-pool / controller** y su consecuencia en la UI (mostrar montos de 0 decimales). | PUENTE §3.4, §4 | ▶ decidido acá, falta construir |

---

## 8. Impacto en el código

> **Estado 09-08-2026:** esta sección se escribió como trabajo futuro y ya no lo es. Las tres
> tablas están **ejecutadas** salvo lo que marca [`ESTADO.md`](ESTADO.md) §5. Lo que queda
> pendiente de este capítulo, en concreto: **calibrar** el precio terminal contra la producción
> por acción (sigue abierto), y **cablear el pool real** en lugar de `MockParticipation`
> (ver [`dobx-pro/docs/PUENTE.md`](../../dobx-pro/docs/PUENTE.md) §3).

### `dobx-contracts`
| Acción | Qué |
|---|---|
| Crear | **`DOBX`** (token de plataforma), **`AgentController`** (admin del pool + custodia del B retenido con cliff) |
| Eliminar | `AgentConverter`, `AgentBuyback`, `AgentTreasury`, `TokenomicsFactory` |
| Modificar | `AgentBondingCurve`: liberación de reserva contra quema de A (§4) |
| Mantener | `AgentShareToken`, `AgentAMM`, `OperatorStake` |
| Configurar | `AgentLaunchpad.setQuoteToken(DOBX)` — y **relanzar** los agentes existentes (§2) |
| Calibrar | precio terminal de la curva contra la producción por acción del pool (§3.4) |

### `dobx-pro/apps/api`
| Archivo | Cambio |
|---|---|
| `services/tokenize.service.js` | pasar `payoutMode = 0`, `payment_token = A`, admin = `AgentController`, `participation_to_sale`, gracia, descuento y duración al crear el pool; dejar de fijar `participants: [{operator, 100}]` |
| `services/payout.service.js` | eliminar `operator_split_bps` y toda la lógica de buyback (`buyback_bps`, `buyback_address`, leg 1); el router queda solo con la pata de distribución |
| `services/evm-launch.client.js` | eliminar `fundBuyback`, `deployTokenomics` |
| `config.js` | eliminar `defaultOperatorSplitBps` |
| `db.js` | migrar: fuera `buyback_bps`, `buyback_address`, `converter_address`, `treasury_address`; entra `controller_address` y la config de pool del creador |
| `services/market.service.js` | `convert()` deja de ser "vender A + comprar B a $1"; pasa a ser la contribución a la campaña. `TERMINAL_PRICE` deja de ser hardcodeado |
| `routes/agents.routes.js` | eliminar el `$1 = 1 B` mock; B se adquiere solo por conversión |

### `dobx-pro/apps/web`
| Qué | Cambio |
|---|---|
| Wizard de tokenización | los 5 parámetros de §6 con presets y acoplamientos en vivo |
| Página de agente | mostrar gracia, calendario, producción restante, piso actual de A, % retenido por el creador |
| Flujo de conversión | un paso (contribuir a la campaña con A), no dos |
| Trading | precios en DOBX, no en USDC |

---

## 9. Resumen ejecutivo

1. **Un solo camino de entrada:** DOBX → A (curva/AMM), modelo Virtuals. A es perpetuo,
   especulativo y su mercado es permissionless.
2. **Una conversión one-way 1:1 con mismo cap** hacia B, que es la participación de un pool de
   DobProtocol — **abierto**: sin monto, tasa ni plazo; se sale vendiendo B.
3. **El A convertido se inmoviliza** (crowdfunding con `payment_token = A` y `payoutMode = 0`),
   y esa quema es lo que libera reserva de la curva hacia el capex del activo.
4. **El `AgentController` es el admin del pool**, no una wallet: eso convierte "inmovilizado" en
   una garantía verificable y aplica el cliff del B retenido.
5. **El 100% del ingreso x402 aterriza en el pool.** Todos los cortes viven en la cap table. La
   ganancia del operador es su `participation_to_sale` retenido, pari passu con los inversionistas.
6. **El período de gracia separa las fases:** año 1 puro mercado de atención para A; después,
   migración hacia renta.
7. **Lo legal se resuelve en el cruce:** KYC/compliance de DobProtocol sobre el paso A→B.
8. **El creador navega cinco parámetros acoplados**, con presets que hacen visibles los
   trade-offs — hoy los tomaría a ciegas porque ninguno está expuesto.

Se elimina: buyback, converter, tesorería B, factory, oráculos, TWAP, keeper, MEV, y el split
off-the-top. Se gana: un solo precio de entrada, un piso mecánico para A, financiamiento
auto-alineado, auditoría completa en la address del pool, y un sink real para DOBX.

Se paga con: **el encaje restringido a activos ya financiados** (§4.3), **la exposición del piso
de A al FX de DOBX** (§3.3), y sobre todo **la tensión entre el sink de DOBX y el financiamiento
del capex** (§4.2), que es el pendiente más urgente.
