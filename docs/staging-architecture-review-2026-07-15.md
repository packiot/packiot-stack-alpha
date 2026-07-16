# Staging Architecture Review — Findings & Fix Batch

**Date:** 2026-07-15 · **Method:** 10-squad read-only diagnostic (8 consistency squads + SparkPlug-removal + offline-resilience), cross-referenced into one reconciled picture. · **Scope:** staging stack (F1/F2/F3 flows), prod SELECT-only reference.

---

## Verdict

**The architecture is structurally SOUND.** Skeleton, plumbing, ingestion, SparkPlug protocol, DB schema, and *raw* data replication are all healthy across F1/F2/F3. The real issues live in two layers: **(1) derived/computed data planes that got orphaned mid-migration**, and **(2) observability that's dark — which is why the orphaned planes went unnoticed.** Plus the tp=3 line-OEE correctness (a known sim-feed limitation, not a compute bug), and a handful of low-severity items including one security flag.

**Answer to the driving question ("is it properly representing the client replicated data?"): raw data YES, computed OEE PARTIALLY — some derived planes are frozen because their legacy producers were retired before the new ones went live.**

---

## The mental model (resolves "I'm lost")

It's **one pipeline, photographed three times, plus two feeder hoses** — not one pipeline. ~30 containers because the *transition itself* is in-frame (new path running alongside the old path it will retire; ~⅓ is scaffolding with a scheduled death).

- **One source of truth** = the counter stream (staging: `plc-sim`; CPACK: real prod via `mirror-worker-go`; Incoplast: real factory via `ingest-shim`).
- **Three renderings run side-by-side to diff them:** F1 = incumbent (compute-in-Postgres), F2 = deliberately-dumb control (stays raw so F3's fixes have a baseline — **F2≠F3 is often *success*, not a bug**), F3 = flip target (compute-in-Go).
- **Two feeder hoses:** the `source_type` triple-emit only carries `equipment_values` (counters); operator decisions live in `user_logs` (F1 only) → **`shadow-mirror`** replays them onto F2/F3; Incoplast's bespoke UI bypasses the API → **`operator-adapter`** translates it.
- **The load-bearing rule:** **join by natural key (`packml_topic`/name), NEVER by `id_equipment`** — surrogate ids deliberately differ across staging/shadow/prod.

---

## Findings by area

| Area (squad) | Verdict | Key finding |
|---|---|---|
| Cross-component wiring (5) | ✅ sound | Fleet healthy, all RMQ queues drained; one anomaly: unexplained `edge-api-db` container not in `compose.staging.yml` |
| Message ingestion (2) | ✅ healthy | edge-transformer receives 100% correct messages; 0 loss/malform/mis-route; every NDATA → exactly 3 confirmed publishes |
| Dead Grafana tile (3) | 🟠 dashboard bug | **4 v1 boards** (`07-mirror`, `08-worker`, `09-bake`, `10-edge-transformer`) omit a datasource → fall to Postgres default → PromQL fails. Engine + metrics healthy. Fix = pin `packiot-prometheus` uid |
| Shadow mirror (1) | 🟡 raw yes / computed no | Plumbing healthy, raw replication faithful (hierarchy/events/values match prod). **F1 `production_orders_runtime` FROZEN since ~07-12** |
| Operator mirror (4) | 🟡 works-for-parity / degraded-fidelity | PO lifecycle + events replay clean (parity substrate intact). **Operator *classifications* (justify/edit/split) silently don't propagate** (Go-rewrite dropped the handlers) — harmless to parity. operator-adapter unproven (never exercised) |
| DB-layer (6) | ✅ consistent | No stale-cagg recurrence; schema parity exact; triggers consistent. **F3 missing PKs** on `production_orders_runtime` + `equipment_events` (F2 has them) — real F2↔F3 inconsistency on the flip target |
| Data lineage (7) | 🟡 F3 clean / F1 frozen | F3 end-to-end fresh + clean dedup + clean referential integrity. **Weakest link = tp=3 line-OEE>1.0** (F3 max 7.3× vs F2 26,346× → **#456 verified working**; residual = sim feed, machines clean). SECURITY: hardcoded prod pw in git |
| OT / PLC / MQTT / UNS (8) | ✅ protocol-correct | SparkPlug B receiver textbook-correct; mosquitto healthy. **`uns_equipment_current_metrics` frozen all flows + prod 55d** — legacy producer retired, replacement built-but-OFF. `lead_machine` NULL = faithful to prod (not a gap) |

---

## The meta-theme: orphaned data planes

The single most important pattern. The migration **retired/disabled legacy producers before their new-stack replacements went live**, stranding derived objects:

| Orphaned plane | Legacy producer | New producer | Fix |
|---|---|---|---|
| `production_orders_runtime` (F1) | pg_cron proc — **disabled** after timing out on the undersized DB | fix+re-enable proc OR the DB ceiling relief | ties to DB resize (task #5/#25) |
| `uns_equipment_current_metrics` | Node-RED proc — **retired** at 10.9 | `current_metrics.go` — **built but behind an OFF flag** | flip `UNS_CURRENT_METRICS_ENABLED=true` (#28) |

Both are **frozen on prod too**, so they're real client-facing gaps, not just staging artifacts. One is a flag-flip; the other is gated on the DB ceiling.

---

## Cross-reference reconciliations (apparent contradictions resolved)

- **"Rollups fresh" (6) vs "OEE frozen" (1/7):** both true — `equipment_runtime_shift` (a *cagg*) is fresh; `production_orders_runtime` (a *pg_cron proc*) is frozen. Different machinery.
- **"Dead tile" (3) vs "engine healthy" (2/5):** the tile is purely a dashboard datasource mis-binding; ingestion + metrics are verified healthy from two independent angles. Triple-confirmed.
- **#456 verified from a third angle (7):** F2 (no suppression) hits OEE 26,346×; F3 (with #456) caps at 7.3× → #456 killed the two-writer double-count; the residual line-OEE>1.0 is the sim-feed class (#16), not a regression.
- **F1 cagg "read-fresh" (6) vs "materialized-stale" (7):** both true — real-time aggregation masks stale materialized watermarks on reads.
- **`lead_machine` NULL "gap" → not a gap (8):** prod itself is NULL on 153/154 lines; staging faithfully mirrors it.

---

## Prioritized fix batch

| Pri | Fix | Owner | Effort |
|---|---|---|---|
| P1 | Flip `UNS_CURRENT_METRICS_ENABLED=true` (self-heals the frozen UNS snapshot) | backend/devops | flag flip |
| P1 | Fix/re-enable `piot_proc_refresh_runtime` OR resize the DB (unfreeze F1 OEE) | dba+devops | ties to #5 |
| P1 | Pin `packiot-prometheus` datasource on the 4 dark dashboards | devops | dashboard JSON |
| P2 | Add missing PKs on F3 `production_orders_runtime` + `equipment_events` (#60) | dba | CONCURRENTLY at prod scale |
| P2 | Reconcile the unexplained `edge-api-db` container vs compose | devops | investigation |
| P2 | Re-introduce operator classification-replay handlers (or accept as F1-retires) | backend | scoped |
| SEC | Rotate + de-hardcode the prod DB password in `cq-logs-bigquery` | devops/security | rotate + purge git |
| — | Client data-quality flags: prod UNS frozen 55d; prod L4/L5 oee>1.0 | report/client | flag |

---

## SparkPlug removal — feasibility verdict

**"SparkPlug" is two separable things.** The confusion behind "let's remove it" comes from conflating them:

- **(A) Transport encoding** (protobuf over MQTT, birth/death, aliases, seq) — **already optional per-tenant.** Incoplast runs entirely without it (HTTP-JSON via `ingest-shim` → the same `oee` exchange). The stack is *already* SparkPlug-transport-optional.
- **(B) Data model / semantic contract** (the metric namespace + PackML 30700-30899 + `packml_topic`→`id_equipment` resolution) — **the backbone of the whole pipeline; not removable without rewriting ingestion + the OEE contract end-to-end.** Even Modbus/S7/OPC-UA re-encode *into* this model. It's not the floor — it's the *waist*.

**Recommendation: keep SparkPlug.** No concrete pain motivates removal (the usual reasons — slow JS decode, heavy dependency, tenant-can't-speak-it — are all *already solved* by ADR-0010's Go decode + the ingest-shim path). The real cleanup is **naming**: the canonical envelope is called "sparkplug" everywhere even on the non-SparkPlug HTTP path — a small ADR renaming the *contract* (vs its *primary encoding*) removes the conceptual debt without touching a byte. The "removal win" people actually want is finishing ADR-0010 Phases 4-5 (delete the remaining Node-RED SparkPlug decode).

---

## Offline / internet-outage resilience (operator + VM client)

**Verdict: robust on the MACHINE-DATA plane; HONEST but NON-DURABLE on the operator plane.** Key topology fact (ADR-0021): **`edge-api` + PostgreSQL are CLOUD-tier** — operator writes always cross the factory→cloud link; **no factory-local durable write target exists** (the C3 edge-operator variant is scaffold only, and even it keeps edge-api+Postgres cloud).

- **Machine data (PLC → cloud):** genuinely offline-tolerant — the edge-transformer **SQLite outbox** is crash-consistent, buffered (100k cap, FIFO drop-oldest ≈ ~8min at peak), ordered replay, idempotent downstream (`UNIQUE(ts_value,id_equipment)`). The one truly resilient path.
- **Scenario A — tablet loses internet:** reads degrade gracefully (PWA cache, *if* the app was loaded online before); writes **fail-closed** (refused + "reconnect and try again" toast — **not silently lost**, but **intent is discarded**, there's no queue). **Sharp edge:** `navigator.onLine` is a link-layer signal, not reachability — flaky-but-associated wifi (the common factory case) → guard doesn't fire → write hangs the 180s axios timeout → generic error.
- **Scenario B — VM/edge box can't reach cloud:** operator writes have **NO local durability** (`operator/src/Services/writeQueue.js` is an inert `NOT_IMPLEMENTED` stub); PLC data is buffered by the outbox. CPACK has no factory VM in the operator path anyway (tablet → cloud edge-api direct), so it collapses to Scenario A.
- **HEADLINE GAP:** operator-action durability under partition **does not exist** — deferred by design (C3), gated behind C1 idempotency + live-tenant validation.
- **Missing for true offline tolerance:** a durable local operator write queue (IndexedDB + client-generated idempotency keys, replay on reconnect); server-side idempotency **+ staleness/conflict rejection** (never blind-replay a write whose PO state moved on); a **reachability heartbeat** replacing `navigator.onLine` (catches flaky wifi, kills the 180s hang); extend the outbox store-and-forward pattern to the operator path.

Offline fix-batch additions:

| Pri | Fix | Owner | Effort |
|---|---|---|---|
| P2 | Reachability heartbeat replacing `navigator.onLine` (kills 180s hang on flaky wifi) | frontend | small |
| P2 | Make `OUTBOX_ENABLED` default-safe (defaults false in code; only staging compose sets it) | backend | small |
| P3 | Durable local operator write queue (the deferred C3 `writeQueue` + idempotency + staleness rejection) | frontend+backend | the real fix, scoped |
