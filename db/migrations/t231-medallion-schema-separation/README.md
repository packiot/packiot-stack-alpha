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
| 4 · silver | fact hypertables → `silver` + FDW re-point (**live ingest**) | **NOT STARTED** — needs code+deploy |
| 5 · cleanup/contract | fix hard-coded `public.`; drop gold shims; codify code lift | **NOT STARTED** |

**Stopped deliberately at the post-gold boundary** — a clean, fully-reversible
point that leaves live ingest untouched. Silver is a distinct high-risk
live-ingest unit (Go refactor + build + deploy of the ingest service + hypertable
move + FDW re-point with zero-gap continuity gating) that deserves its own focused
session with full runway.

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
