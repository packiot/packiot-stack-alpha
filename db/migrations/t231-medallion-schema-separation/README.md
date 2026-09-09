# t231 — Medallion schema separation (bronze / silver / gold) for `packiot_analytics`

**Scope:** STAGING `packiot_analytics` @ 10.10.10.89 only. Prod (`packiot40`) is a
later forward-port — do NOT apply here. Design: `docs/plans/medallion-schema-separation.md`.

Phased **expand/contract**. Each phase applied → hardproof gate → next. Symmetric
`.down.sql` for every phase.

## Status (2026-09-09)

| Phase | What | State |
|---|---|---|
| 1 · bronze | `equipment_values_raw`, `equipment_events_raw` → `bronze` (dormant, 0 chunks) | **APPLIED + GATED** |
| 2 · search_path | DB default `"$user", gold, silver, bronze, public` | **APPLIED + GATED** |
| 3 · gold (expand) | 12 computed OEE grains → `gold` + public shim views | **APPLIED + GATED** |
| 4 · silver | fact hypertables → `silver` + shims + FDW re-point (**live ingest**) | **APPLIED + GATED** |
| 5 · cleanup/contract | code lifts → silver/gold; `purge_analytics_plain` → gold; shim DROP deferred | **PARTIAL** — proc fixed + code lifts committed; shim DROP gated |

### Phase 4 (silver) — cutover result (2026-09-09 ~02:08 UTC)
`equipment_values`, `equipment_events`, `equipment_live_metrics` moved to `silver`
with auto-updatable `public` shim views (migration `04`). Executed during a
**stream-engine stop** (the rollup pool's long AccessShare read on
`equipment_values` — an 88s line-lead rollup — could not be beaten by a 4s
`lock_timeout`; stopping the consumer released it → all 3 moved on attempt 1 with
a 30s timeout). Ingest is RabbitMQ-durable, so the consumer's messages buffered in
the queue during the stop and drained against `silver` on restart.

**Ingest routing** now per-layer (`services/stream-engine/.../handlers/sparkplug.go`
`route{silver,bronze,ev}`): facts→silver, raw→bronze, DQ + PO control→public. Only
the staging `refactored` analytics route (analyticsPool != nil) fans to
silver/bronze — prod single-flow stays on public until the forward-port.

**FDW re-point:** `live.equipment_values` + `live.equipment_events` →
`schema_name 'silver'` on the hist-gateway (and the init script). Literal-timestamp
pushdown to `silver` proven **68 ms** fresh; `ev_all` resolves hot(silver FDW)∪cold.

**Gate results (all GREEN):** `silver.equipment_values` `max(ts_value)` advancing
(multi-sample); silver caggs + 4 compression/retention policies followed by OID;
rollup gold on normal hourly cadence (transient post-restart `hour reflag`
deadlocks self-cleared); no `42P01`/`500` in read-api/edge-api/analytics-sync;
analytics-sync `equipment_events` INSERT-ON-CONFLICT+UPDATE traverse the public
shim (hardproofed on a throwaway hypertable+view).

**⚠ First attempt aborted + rolled back:** the initial deploy-first attempt hit the
lock contention above and the ingest window opened while facts still lived in
public → ~736 window messages (02:02–02:04) exhausted retries into the `*-failed`
queues. Rolled the binary back to restore ingest, then re-cut via the stop-move-
start path. A failed-queue replay mistakenly preserved the `x-death` header
(consumer's `retries>=MaxRetries` guard re-failed them + cpack→sbxcpack fanout
amplified) → the failed queues were purged after most window data was re-UPSERTed
into silver (deduped by `ts_value`; residual is a self-healing cumulative-counter
gap on staging). RULE: dead-letter replay MUST strip `x-death`/reset retry count.

### Phase 5 (cleanup) — done vs deferred
- **DONE (committed, code lifts):** `analytics-sync` (`equipment_events`→silver,
  `_man` stays public), `stream-engine` `bake.go`/`cmd/port-parity`,
  `mirror-worker-go`, `parity-check.sql` — facts `public.`→`silver.` (take effect
  on next deploy; traverse the shim until then).
- **DONE (applied):** `purge_analytics_plain` repointed off the public gold shims →
  `gold.equipment_oee_{hourly,shift}` (migration `05`); `equipment_events_cpac_shadow`
  stays public.
- **N/A:** terraform `db_init.sh` retention/VACUUM cron targets the MAIN `packiot`
  DB (`cron.database_name=${db_name}`), NOT `packiot_analytics` — its
  `public.equipment_values` was never moved. Analytics retention rides the
  TimescaleDB policies that followed the move.
- **DEFERRED (gated, #186):** DROP the gold (03) + silver (04) public shim views —
  only after the code lifts are DEPLOYED and a zero-writer log-watch confirms no
  service references the `public.` fact/grain names.

### Phase gate results (hardproof)
- **Bronze:** raw tables in `bronze`; compression+retention jobs 1027-1030 followed
  automatically; 0 view/rewrite dependents; ingest unaffected.
- **search_path:** fresh connection shows widened path; all 12 unqualified
  serving/report functions resolve; `serving.pending_downtime` executes; ingest flat;
  read-api healthy.
- **Gold:** 12 grains in `gold` + 12 public shim views. Rollup writes land in gold
  via the shim — PROVEN: `gold.equipment_oee_hourly.computed_at` advanced
  01:17:30 → 01:22:16 during a rollup tick. edge-api `INSERT ON CONFLICT
  (id_equipment,ts_value)` traverses the shim to the gold PK arbiter (EXPLAIN).
  analytics-sync UPDATE/INSERT traverse the shim (EXPLAIN). `bi.oee_hourly`=8721,
  `bi.production_order_runtime`=18817 with tenant context (OID-followed to gold).
  No 42P01/500 in read-api/stream-engine/analytics-sync logs. Ingest flat.

## Gold set (decided)
MOVED to gold: `equipment_oee_{shift,hourly,daily,weekly,monthly}`,
`equipment_oee_shift_{weekly,monthly}`, `area_oee_{daily,shift}`,
`site_oee_{daily,shift}`, `production_orders_runtime`.
STAY in public: `oee_targets`, `production_targets`, `scrap_targets` (target CONFIG,
not computed grains), `h_piot_oee_*` (Hasura serving), `production_orders` (dimension).

## box_scans / po_box_counter — LEFT in public (follow-up)
The design doc classifies bronze as ONLY the immutable `_raw` landing tables.
`box_scans`/`po_box_counter` are live transactional barcode data written by the
edge-api scanned-boxes DAO (`POST /api/scanned-boxes`, feat/230, just landed).
Moving them for a label the design doc doesn't endorse would add
INSERT-through-view / pgbouncer-bounce risk to a live write path for no analytical
benefit this pass. If barcode-Bronze is later desired: move + public shim views
(DAO uses unqualified `box_scans` + `INSERT`/`ON CONFLICT` on `po_box_counter` —
verify the conflict target is a column list so it traverses the shim), gated on a
live `POST /api/scanned-boxes` proof. edge-api staging primary DB IS
`packiot_analytics` via pgbouncer, so the DB search_path applies after a pool bounce.

## PHASE 4 (silver) — precise scope for the next session
The single routed ingest `schema` (`flows.Dest.EvSchema` = `"public"`, hardcoded in
`services/stream-engine/internal/flows/flows.go:52`) currently feeds a MIX of
targets, so silver is NOT a single-value flip:

| Writer (routed `schema`) | Table | New home |
|---|---|---|
| `writers/equipment_values.go` fact UPSERT | `equipment_values` | **silver** |
| `writers/equipment_values.go` BuildEventMint | `equipment_events` | **silver** |
| `writers/po_parameter.go` | `equipment_values` | **silver** |
| `writers/uns_current_metrics.go` | `equipment_live_metrics` | **silver** |
| `writers/equipment_values.go` Build*Raw (dormant) | `*_raw` | **bronze** |
| `handlers/sparkplug.go` clampDQInsertSQL | `data_quality_event` | **public** |

Code lift (per design §7 option B):
1. `flows.Dest`: add `BronzeSchema`, `SilverSchema`, `GoldSchema`. Staging dest =
   `{EvSchema:"public", RefSchema:"public", BronzeSchema:"bronze", SilverSchema:"silver", GoldSchema:"gold"}`.
2. Thread `SilverSchema` to the fact/event/po_parameter/uns writers; `BronzeSchema`
   to the raw append; keep `data_quality_event` on `public` (EvSchema).
3. Keep the rollup on `EvSchema="public"`: it reads `equipment_values` via a public
   READ shim (see below) and writes gold grains via the gold shim — no rollup change.
4. Fix hard-coded `public.` (design §3.4): `bake.go`, `cmd/port-parity`,
   analytics-sync `replicate/handlers.go`, mirror-worker `db/staging.go`, terraform
   `db_init.sh` drop_chunks/VACUUM, `purge_analytics_plain`, edge-api trigger migration.
5. `go build` + tests, deploy stream-engine (pipeline GREEN, dup-IP fix #1151).

DB move (zero-gap discipline — design §6.3):
- `ALTER TABLE public.equipment_values SET SCHEMA silver` (+ `equipment_events`,
  + `equipment_live_*`), lock_timeout+retry.
- Create public READ shim VIEWs `public.equipment_values`/`equipment_events` →
  `silver.*` for READERS (rollup, bake, mirror-worker, terraform, serving). Do NOT
  route the ingest WRITER through the shim (ON-CONFLICT UPSERT into a hypertable via
  a view is the risky path — OPEN: hardproof this in a throwaway schema before
  relying on it; the safe plan is writer-targets-silver-directly + reader-shim).
- Re-point the historian-gateway FDW on the hist-gateway container:
  `ALTER FOREIGN TABLE live.equipment_values OPTIONS (SET schema_name 'silver');`
  (+ `equipment_events`); baseline is `schema_name=public`. Edit
  `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh:117,120`.
- HARD GATE: `max(ts_value)` on `silver.equipment_values` advances throughout; cagg
  watermark continuity; FDW `live.equipment_values` fresh rows post-repoint; `ev_all`
  no double-count; read-api/Superset no 500s; rollup still writes.

## PHASE 5 (cleanup/contract)
- Drop the gold public shims once rollup + analytics-sync + bake are confirmed off
  `public.` grain names.
- Point `Dest.BronzeSchema` at `bronze` for the raw append.
- Codify the stream-engine code lift as a PR.
