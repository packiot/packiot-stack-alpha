# ADR-0061 — Remove PackML from the cloud: identity declared at birth, roles declared in the descriptor

**Status:** Proposed · **Date:** 2026-10-07 · **Decision owner:** user (decisions below taken 2026-10-07)
**Supersedes:** [ADR-0047](reference/adr-0047-packml-is-internal-wire-contract.md) (cloud scope: "keep PackML as the
internal wire contract") and [ADR-0051](0051-packml-register-generated-only-and-unroutable-alerting.md) (`packml_register`
as the cloud routing table). **Completes:** [ADR-0046](0046-edge-source-plugin-contract.md) §4 ("bind at birth … delete the
scaffold"). **Shipped to clients:** every producer change below runs on client edge boxes.

---

## 1. Context

### 1.1 What "PackML" means here (verified 2026-10-07)
On the wire the cloud only receives SparkPlug B: a 60 s census of staging MQTT showed `spBv1.0/<group>/…` topics only.
But SparkPlug is the envelope. Every metric **name** inside it is `<packml_topic><suffix>`
(`CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount/N/Unit`), and the cloud derives three things from that string at runtime:

| Derived from the PackML name | Where | Live volume (staging `pg_stat_statements`) |
|---|---|---|
| **identity**: metric → `id_equipment` | stream-engine `sparkplug/resolver.go:118-131` (`… WHERE pr.packml_topic = $1`) | 257,533 calls |
| **tenant**: queue per enterprise | stream-engine `tenants/discovery.go:36-41` (`split_part(packml_topic,'/',1)`) | 17,895 calls |
| **meaning**: counter / status / parameter | stream-engine `sparkplug/parse.go:151-283`, decoder calc `decision_tree.go`, Parameter IDs 30700–30899 (`pocontrol`, `line_param30700_seed.go`) | per message |

`core.packml_register` is a compat view over `core.topic_routing`: 479 rows, **all** keyed by `packml_topic`, none by
`mqtt_topic`; `device_key` is missing on 43 of the largest client's 156 rows. Downstream, the operator SPA uses
`packmlTopic` as its line identity, read-api serves operator routes, shift functions and external customer APIs by topic,
the sync06 report writes a `packml_topic` column, and onboarding/CS Admin *create* topics from names
(`buildPackmlTopic`, `generate.go:522-565`). On-prem (`compose.onprem-edge.yml`) has **no** PackML routing at all.

### 1.2 Why remove it
An identity derived from names breaks four features the user named (2026-10-07):
1. **Customize derived/calc tags** (ADR-0058): a derived metric has no PackML name to parse.
2. **Third-party edge sources** (HighByte, client tees; ADR-0046): they don't speak our naming.
3. **Renames and restructuring**: renaming a site, area, line or equipment changes the topic, so routing and history break.
4. **Multi-PLC / line aggregation**: a line fed by several PLCs has no single natural topic.

The root cause is the same in all four: **identity and meaning are derived from a string instead of declared once**.

### 1.3 Prior art already in the repo
- ADR-0046 designed the replacement: *bind at birth*, *identity is declared, not derived*. Our agent already stamps
  `properties["device_key"]` on definitive births (`internal/agent/birth/birth.go`).
- **But the agent still falls back to deriving `device_key` from the PackML topic** when none is declared
  (`birth.go:44-47`), so PackML coupling survives inside the new path.
- There are **two** resolution points: the decoder's birth-bound router (`BIRTH_BOUND_ROUTING`, off on staging) and
  stream-engine's PackML resolver (on). Neither is authoritative for both.

## 2. Decisions

### D1 — Identity is declared once, at SparkPlug birth
Every equipment has a stable, opaque **`device_key`** declared in the client descriptor (never derived from names). Every
producer puts it in the DBIRTH (`properties.device_key`). The cloud binds `(id_enterprise, edge_node, device) → device_key →
id_equipment` **at birth** and resolves data messages through that binding. No message is resolved by parsing a name.
- A birth with an unknown `device_key`, or data for a device with no valid birth, is **quarantined** (unroutable queue +
  alert + rebirth request). Never guessed.
- **The derivation fallback is deleted:** a descriptor without `device_key` fails validation at onboarding.
- **One binding authority:** the decoder resolves at birth and stamps `id_equipment`/`id_enterprise` on what it
  publishes. stream-engine consumes ids and stops resolving.

### D2 — Meaning is declared, not parsed
Each metric's **role** (gross / net / scrap counter, status, speed, PO command, setup parameter, analog, derived) is
declared in the descriptor and carried in the birth (`properties.role`). Consumers dispatch on role.
- The PackML leaf-name classification (`parse.go`, calc decision tree) is deleted.
- **Parameter IDs 30700–30899 are replaced by declared roles** (user: only our edge uses them, no client PLC depends on
  them).

### D3 — Tenant comes from the binding
The tenant is `id_enterprise`, from the birth binding and the SparkPlug `group_id ↔ id_enterprise` mapping in
`core.enterprises`, not `split_part(packml_topic, '/', 1)`. Queue names stay per tenant; their key becomes the enterprise.

### D4 — Producers are natively conformant (no emulators, no adapters)
Decision (user, 2026-10-07): permanent solution only; **nothing synthesizes births on another producer's behalf**.
- **sparkplug-agent** (our edge box, all clients): declared `device_key` + roles required; fallback removed.
- **ingest-shim** becomes a proper SparkPlug **gateway edge node**. Its HTTP ingest contract v2 requires `device_key` and
  role per sample, and it issues births for the devices it represents. That is SparkPlug's gateway model, not emulation.
  v1 producers (Incoplast's Node-RED) migrate to v2.
- **operator-gateway** resolves by `id_equipment` / `device_key`, not topic.
- **plc-sim** and the legacy edge Node-RED either emit conformant births or are retired.

### D5 — Data model
- `core.topic_routing` becomes **`core.device_bindings`**: `(id_enterprise, device_key) UNIQUE NOT NULL → id_equipment`,
  `active`, `edge_node`, `device`, audit timestamps.
- After cutover the `packml_topic`, `mqtt_topic` and `sparkplug_json` columns, the `packml_register` views and their
  sequence are dropped.
- `piot_get_*_by_packml_topic*` functions get `*_by_equipment` replacements; serving views that carry `packml_topic`
  switch to ids.

### D6 — Contracts are versioned; the old field gets a deprecation window
Decision (user, 2026-10-07).
- External integration APIs (including the Incoplast/Montebello endpoints), the sync06 report and operator routes get
  **v2, id-based** shapes.
- v1 keeps its `packml_topic` field, filled from a **computed display path** (enterprise/site/area/line/equipment names).
  It is not used for routing, so renames stop breaking anything.
- The field is removed after the deprecation window (§4).
- The operator SPA's identity becomes `id_equipment`.

### D7 — Rollout for shipped clients: per client, gated, reversible
1. **Coverage gate:** 100 % of active bindings have a declared `device_key` (today 43 of the largest client's 156 rows
   don't), and every device of the client has sent a conformant birth.
2. **Verification run** before each client's switch. Birth-bound resolution is computed next to the current resolver
   on live traffic and compared; only the current resolver writes. Mismatches are counted per client and alerted. This
   is a temporary measuring instrument, removed in P5: not an emulator, nothing is written through it.
3. **Switch** that client after zero mismatches for 7 consecutive days. Rollback = the per-client flag, until P5.
4. Clients switch one at a time, starting with the one whose blocked features are most urgent.

### D8 — Deletion is part of the definition of done
- P5 deletes: the PackML resolver, tenant discovery by topic, leaf-name classification, `TopicForRegister`/`CanonicalTopic`,
  `buildPackmlTopic`, the "Machine addresses" (packml-register) CS Admin page, the generate-packml-config endpoint, the
  packml-register CRUD, and the DB objects in D5.
- A CI guard fails the build if `packml` (case-insensitive) reappears in cloud services
  (`services/**`, `edge-api/src`, `csadmin/src`, `operator/src`, `db/migrations` newer than P5). Explicit allowlist:
  v1 deprecation shims until they expire, and historical docs.

## 3. Phases

| Phase | Deliverable | Unblocks | Done when |
|---|---|---|---|
| **P0** | Descriptor schema: required `device_key` + per-metric `role`; validation fails without them. Backfill `device_key` for every active binding. `core.device_bindings` added next to `topic_routing` | — | 100 % coverage on staging |
| **P1** | Agent: births carry declared `device_key` + roles; derivation fallback removed | third-party sources, derived tags | e2e: agent → decoder birth binding for every staging device |
| **P2** | Decoder = single binding authority, stamps ids; stream-engine consumes ids; tenant from binding; verification run | renames, multi-PLC lines | verification shows 0 mismatches per client for 7 days |
| **P3** | Operator SPA + read-api + edge-api/csadmin on ids; onboarding `device_key`-first; contracts v2 + v1 display-path shim | renames (UI side) | operator flows and external APIs pass on ids |
| **P4** | ingest-shim gateway v2; operator-gateway by id; client migrations (Incoplast first) | third-party sources | no v1 producer left |
| **P5** | Per-client switch done; deletions (D8) + CI guard; ADR-0047/0051 marked superseded | — | `packml` guard green |

## 4. Consequences and open questions

**Good.** One identity, declared once, survives renames and moves. Any SparkPlug producer that declares its births
plugs in. Derived and multi-source metrics get a real home. The hot path loses a string-parse and a lookup per message.

**Costs.** Every client edge box gets a new agent and descriptor (shipped). External API consumers must move to v2
within the window. Two resolvers coexist until each client switches.

**Open questions**
1. Deprecation window for v1 contract fields: 90 days?
2. SparkPlug `group_id` ↔ `id_enterprise` mapping: a new column on `core.enterprises`, or derived from the descriptor?
3. History: the time-series tables are keyed by `id_equipment` already; check that no gold/serving object re-joins
   history by topic (to be audited in P0).
4. legacy-replicator maps legacy → staging equipment by topic; retire it or give it an id map (it is transitional).
