# Edge-Source Topic Contract (NORMATIVE)

**Status:** Official · **Version:** 1.0 · **Date:** 2026-07-30 · **Governs:** [ADR-0046](../adr/0046-edge-source-plugin-contract.md)

This is the **definitive, single** topic layer for the Packiot stack. Any edge source —
the native `sparkplug-agent`, a client Node-RED tee, `plc-sim`, **HighByte**, or any future
producer — is a conformant edge source **iff** it satisfies this contract. There is no "v1"
and no "v2": the legacy string-grammar (Appendix A) is a retiring scaffold, not a supported
form. Keywords **MUST / MUST NOT / SHOULD / MAY** are RFC-2119.

---

## 1. Transport (mosquitto, SparkPlug B)

The definitive ingress is **SparkPlug B over the internal `mosquitto` broker**. A producer
MUST publish to:

```
spBv1.0/<group_id>/<message_type>/<edge_node_id>/<device_id>
```

- `<group_id>` **MUST** be the tenant short-code (e.g. `CPACK`, `BISNAGO`). It is the **only**
  authority for tenant identity. The tenant **MUST NOT** be repeated inside metric names.
- `<message_type>` ∈ `NBIRTH · NDATA · NDEATH · DBIRTH · DDATA · DDEATH · NCMD · DCMD`.
- `<edge_node_id>` identifies the producing gateway (e.g. `sparkplug-agent-cpack`,
  `highbyte-cpack`). It **MUST** be unique per tenant.
- `<device_id>` is the **equipment device key** (§3). Present on `D*` messages.

HTTP fallbacks (`ingest-shim :8444`, `sparkplug-agent :9104 /v1/counters`) exist **only**
for producers that cannot speak MQTT; they MUST carry the same declaration (§2–§4).

## 2. Identity is DECLARED at birth, never derived

Each equipment is a SparkPlug **device**. On `DBIRTH` (or `NBIRTH` for a node-scoped
equipment), the producer MUST establish, per device:

1. the **device key** = `<device_id>`, a stable string the stack resolves to `id_equipment`;
2. for every metric it will later publish, the binding **`alias → (device, counter_role)`**.

The stack (edge-transformer) MUST, on receiving the birth, resolve
`device_key → id_equipment` via **`packml_register`** (the identity SSoT — ADR-0009) and
cache `alias → (id_equipment, counter_role)`. Producers assert **keys**, never ids.

The stack **MUST NOT** derive equipment identity or metric semantics by string-parsing a
metric name at DATA time. Names are display-only (§5).

## 3. Metric declaration (what a birth metric MUST carry)

Per the SparkPlug B `Metric` structure, a counter metric declared at birth **MUST** carry:

| Field | Requirement |
|---|---|
| `name` | human-readable UNS path, **display only** (e.g. `L5/BREYER/gross`). Birth-only. |
| `alias` | uint64, unique within the edge node. The **routing key** carried on every later DDATA. |
| `datatype` | numeric (Int64/Double per the totalizer). |
| **`properties["counter_role"]`** | **REQUIRED.** One of the closed enum `gross · net · scrap` (§4). |
| `properties["device_key"]` | REQUIRED if the equipment is not already fixed by `<device_id>`. |
| `properties["source_ref"]` | **OPTIONAL, lineage only.** The origin PLC index/register/tag. **MUST NOT** be used for routing. |

Non-counter metrics (state, speed) MAY be declared with their own well-known property tags
(out of scope for v1.0 — counters only).

## 4. Counter roles (the closed enum)

`counter_role` **MUST** be exactly one of:

| Role | Meaning | OEE use |
|---|---|---|
| `gross` | total infeed / consumed | quality **denominator** (`oee_q = net/gross`) |
| `net` | good output / processed | quality **numerator** |
| `scrap` | defective / rejected | optional; informational + reconciliation |

No other values are valid. This is the **only** place counter semantics live — the English
counter-name substring (`ProdConsumedCount` etc.) is **NOT** authoritative and is retired
with the scaffold. `gross`/`net`/`scrap` map from the legacy names and from HighByte model
attributes alike.

> A **line** whose roles come from different physical counters declares them as **separate
> role-typed metrics on the line device**. The physical index→role mapping (legacy
> `line_roles`) is resolved **at the edge adapter** and **MUST NOT** appear in the stream.

## 5. Runtime (DDATA)

On `DDATA` a producer MUST send, per metric: `alias` + `value` (+ optional timestamp/quality).
It **MUST NOT** resend `name`, `counter_role`, or `source_ref` (birth-only). The stack routes
`(edge_node, alias) → (id_equipment, counter_role)` from the birth cache — **zero** per-message
string parsing, positional logic, or index lookup.

A DDATA alias with no live birth binding is an **error** → the stack requests a **rebirth**
(ADR-0042) and drops the sample until re-seeded. Fail-closed: an unbound alias is never guessed.

## 6. Conformance

A producer is conformant iff its birth declaration validates against
[`schemas/edge-birth-declaration.schema.json`](schemas/edge-birth-declaration.schema.json)
and its DDATA carries only bound aliases. The golden fixtures under
[`fixtures/`](fixtures/) are the canonical examples; `edge-transformer` and every producer
test against the **same** fixtures — that shared golden is what lets the legacy scaffold be
**deleted** (the schema, not a fallback parser, is the compatibility guarantee).

---

## Appendix A — the retiring scaffold (legacy string-grammar; DO NOT target)

The pre-ADR-0046 form encoded identity + role + index in the metric **name** and parsed it
per DDATA:

```
CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit
└tenant┘ site  area  line  member └─ role by substring ─┘└idx┘ (positional: parts[4]="Admin"⇒line)
```

Its four defects (positional parsing · physical index in the semantic address · identity by
string-prefix · tenant stated twice) are the reason ADR-0046 exists. It is supported **only**
until every producer converges onto this contract, then the parser is **removed**. New
producers **MUST NOT** target it.

## Appendix B — worked example

A line `L5` (gross+net from two counters) and a machine `BREYER` (net), under tenant `CPACK`:

- Transport: `spBv1.0/CPACK/DBIRTH/sparkplug-agent-cpack/CPACK-SC-LINHAS-L5`
- Birth metrics on device `CPACK-SC-LINHAS-L5`:
  - `{name:"L5/gross",  alias:10, counter_role:"gross", source_ref:"idx:168"}`
  - `{name:"L5/net",    alias:11, counter_role:"net",   source_ref:"idx:169"}`
- Runtime: `spBv1.0/CPACK/DDATA/…/CPACK-SC-LINHAS-L5` → `[{alias:10,value:396066},{alias:11,value:365852}]`
- Stack: `CPACK-SC-LINHAS-L5 → id_equipment 40004`; `alias10→(40004,gross)`, `alias11→(40004,net)`.
