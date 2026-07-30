# ADR-0046 — The Edge-Source Plugin Contract (native agent ⇄ HighByte ⇄ any)

**Status:** Draft · **Date:** 2026-07-30 · **Relates:** ADR-0009 (edge-transformer/Node-RED split), ADR-0010 (SparkPlug decode in Go), ADR-0042 (rebirth/alias), ADR-0045 (config-as-data onboarding)

## Context

We want the stack to ingest telemetry from **any** edge producer — our native
`sparkplug-agent` (S7/numeric, descriptor-driven), a client's own Node-RED tee,
`plc-sim`, and — the motivating case — **HighByte Intelligence Hub** — and to swap
between them **per tenant** without touching the ingestion pipeline. Today that
swappability is *emergent* (edge sources happen to be separate, profile-gated
services) rather than a *declared* contract. This ADR makes the edge boundary an
explicit, versioned plugin interface, and — prompted by a review of the topic
layers — corrects the smells that make the current boundary harder to target than
it should be.

Nothing in this ADR removes a component. HighByte becomes a **peer adapter**
behind the same contract the native agent already satisfies.

## 1. The current model (verified 2026-07-30)

Three "topic-like" things at three layers:

| Layer | Example | Role |
|---|---|---|
| **① SparkPlug transport topic** | `spBv1.0/CPACK/DDATA/sparkplug-agent-cpack` | MQTT routing envelope: `spBv1.0/<group=tenant>/<type>/<edge_node>`. edge-transformer subscribes `spBv1.0/+/+/+/+`. |
| **② SparkPlug metric name** (payload) | `CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit` | Canonical semantic address: `TENANT/SITE/AREA/LINE[/MEMBER]/<leaf>`. Equals `packml_topic + metric_suffix`. |
| **③ `packml_topic`** (DB key) | `CPACK/SC/LINHAS/L5/BREYER` | Equipment-identifying **prefix** of ②; `packml_register` joins it → `id_equipment` (+ `tp_equipment`, `id_unit`). |

Runtime flow: NBIRTH seeds an **alias table** (alias → metric name, ADR-0042);
DDATA carries the alias → resolves to the metric name → the name is **string-parsed**
to derive `(id_equipment, counter_kind)`:
- **kind** by substring (`ProdProcessedCount`→net, `ProdConsumedCount`→gross,
  `ProdDefectiveCount`→scrap — the [[oee-leaf-naming-trap|leaf-naming trap]]);
- **line vs member** by position (`parts[4]=="Admin"` ⇒ line, else `parts[4]`=member);
- **equipment** by stripping the leaf → `packml_topic` → register lookup.

**What the PLC has: no topics.** Raw PLCs expose an *address space* — S7 DB offsets
(`DB1.DBD8`), Modbus registers, OPC-UA node ids — or, for numeric-counter clients
(bispharma/bisnago), a bare `counterData:[{id,value}]` with **no strings at all**.
Topics are entirely an *edge construct*: the adapter maps address/id → canonical
name. That mapping IS the anti-corruption layer.

## 2. Senior review — four smells (and their one root cause)

1. **Positional parsing.** `parts[4]=="Admin"` decides line-vs-member. Segment meaning
   depends on ordinal position → a site/area code with an unexpected shape misclassifies.
2. **Physical binding leaks into the semantic address.** The count `index` (`/61/`) is a
   *physical channel id* embedded in the canonical name. Verified: it is **not used
   downstream** — Calc gets the kind from the substring, not the index. It is dead weight
   in the canonical stream, and it is the sole reason the routing requires
   *global count-index uniqueness per tenant* (see [[plc-line-cardinality-count-index-routing]]).
3. **Identity by string-prefix.** `id_equipment` is re-derived by stripping the leaf off
   the name on every message — the fragile "collapsed key" class (4-seg vs 5-seg forms).
4. **Tenant stated twice.** The tenant is both the SparkPlug `group_id` **and** the metric-name
   prefix — two sources of truth for "who," free to drift.

**Root cause:** semantics are re-derived *per DDATA* by parsing a self-describing
string, when SparkPlug already gives us a **birth certificate** to declare them
*once*. We use the alias table for the *name*, then throw the birth context away and
re-parse the name for *meaning* on every sample.

## 3. Decision

**The plugin contract is the BIRTH DECLARATION, not the runtime string grammar.**

An edge source is conformant iff, per device, its **(N/D)BIRTH** binds every published
metric to an explicit **(equipment, counter-role)** — resolvable *without* parsing the
DDATA name and *without* a physical index. Concretely:

- **Bind at birth, not per-message.** At NBIRTH/DBIRTH, resolve each metric's
  `alias → (id_equipment, counter_role)` **once** and cache it. DDATA is then
  `alias + value` → direct `(id_equipment, role)` lookup. No per-sample substring or
  positional parsing. (This is SparkPlug used as designed — the stateful birth model
  is the whole reason SparkPlug exists over plain MQTT; see
  [[sparkplug-rebirth-stateful-recovery]].)
- **Semantics are explicit, role-typed.** A metric declares its role
  (`gross`|`net`|`scrap`) as a first-class attribute, not as an English counter-name
  substring (kills the leaf-naming trap at the contract level).
- **Physical binding stays at the edge.** `count_index` / register / `endpoint` are
  **adapter-internal** — resolved *before* the canonical publish, and at most carried as
  an *optional* birth property for lineage. They are **out of the routing path**.
- **Identity is declared, not derived.** The device→`id_equipment` binding is a birth
  fact (a metric/property in DBIRTH, or the register loader's map), never re-computed by
  slicing the topic string.
- **Tenant authority = the SparkPlug `group_id`.** The metric name need not repeat it.

### The boundary (where a producer connects)

Primary: **canonical SparkPlug B on the internal `mosquitto`** — `spBv1.0/<tenant>/#`.
Fallback: the **HTTP ingest front-doors** already in place — `ingest-shim :8444`
(SparkPlug over HTTPS) and `sparkplug-agent :9104 /v1/counters` (numeric). Any of the
three satisfies the contract as long as the birth declaration conforms.

### The adapter model

```
                       ┌─ sparkplug-agent (S7/numeric, descriptor-driven) ┐
   PLC registers ────► ├─ Node-RED tee (client flow)                      ├─►[BIRTH CONTRACT]─► edge-transformer ─► OEE
   / OPC-UA / Modbus   ├─ plc-sim (synthetic)                             │   canonical SpB     (source-agnostic;
   / bare counter ids  └─ HighByte Intelligence Hub  ◄─ plugs in here ─────┘   on mosquitto        birth-bound aliases)
```

- Edge sources are **peer adapters**, already separate + profile-gated (`client-ingest`,
  `plc-sim`, `cpack-tee`). Per tenant, **exactly one** is enabled (mutually exclusive) via
  the existing profile/`client.yaml` mechanism.
- **HighByte** publishes canonical SparkPlug (models → UNS metrics) to `mosquitto`. Because
  it resolves physical→semantic in its models, its birth is already role-typed with no
  count indices — so it **dissolves smell #2** for the tenants it fronts. The native agent
  keeps serving the S7/numeric tenants that don't need HighByte's protocol breadth.

## 4. Migration (non-breaking, staged)

- **v1 (current, string-grammar birth):** stays fully supported — CPACK is live on it,
  bispharma/bisnago onboarded on it. No forced change.
- **v2 (birth-bound, role-typed, index-free):** new target. edge-transformer gains a birth
  handler that, when a DBIRTH declares explicit `(id_equipment, role)` bindings, caches
  them and **skips** the per-DDATA string parse; when it doesn't, it falls back to the v1
  parser. Producers migrate at their own pace; **HighByte targets v2 directly.**
- **Contract test (the de-risking artifact):** publish a JSON-schema + golden fixtures for
  a conformant birth declaration, so any external producer (HighByte) self-validates its
  output against exactly what edge-transformer accepts — the same golden-fixture discipline
  the Go services already use.

## 5. Consequences

- **Pluggable by declaration, not by luck.** "Which edge source" becomes a per-tenant config
  choice against a named contract; adding a producer is writing an adapter that emits a
  conformant birth, not patching the pipeline.
- **Cheaper, safer runtime.** Birth-bound aliases remove per-message parsing (throughput +)
  and the positional/prefix fragility (correctness +).
- **The count-index constraint becomes adapter-local**, not a stack-wide invariant — and
  vanishes entirely for semantic producers (HighByte).
- **Cost:** a birth-handler code path in edge-transformer + the contract schema/test; the v1
  parser stays until the last v1 producer retires. Net: additive, dual-path during transition.

## 6. Open decisions (surface before building)

1. **Primary boundary for HighByte** — mosquitto SparkPlug (idiomatic, stateful, gets rebirth
   for free) **vs** the HTTP ingest-shim (simpler for a REST-only HighByte output). Recommend
   **mosquitto SparkPlug** as primary; ingest-shim as the REST fallback.
2. **Where the `(id_equipment, role)` binding is authored for v2** — carried in the producer's
   DBIRTH payload, or looked up from `packml_register` keyed by a stable device id? Recommend
   `packml_register` remains the SSoT (ADR-0009), with DBIRTH carrying the stable device key +
   role, so the stack still owns identity.
3. **Role vocabulary** — fix `gross|net|scrap` (+ any others: `rework`?) as the closed contract
   enum, mapped from both the v1 counter-names and HighByte model attributes.
