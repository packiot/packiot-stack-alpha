---
title: analytics-sync (legacy-replicator and shadow-mirror)
layer: 3
owner_area: legacy-bridge
last_verified: 2026-10-13
---
# analytics-sync (legacy-replicator and shadow-mirror)

> **Layer 3 · Components** — the Go module that mirrors CPACK's legacy activity into the
> analytics DB: the live `legacy-replicator` (legacy `packiot40` → staging, plus a sandbox
> instance) and the idle `analytics-sync` (shadow-mirror). For whoever debugs a missing or
> wrong PO or downtime on the CPACK twin.
> Up: [Legacy bridge](../subsystems/legacy-bridge.md) ·
> [README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/analytics-sync/README.md) ·
> [Service catalog](../../reference/service-catalog.md)

## Responsibility

Make the staging analytics DB reflect what CPACK's operators and PLCs do on the legacy
platform: replay each legacy audit row (`user_logs`) idempotently under the analytics
tenant, then copy, by periodic reconcile passes, everything the audit trail cannot carry
(POs created outside it, header and runtime-window drift, product/client links, PLC base
events, manual downtimes). It never computes OEE and never writes to the legacy DB.
It serves no business HTTP API (only `/healthz` and `/metrics`).

## At a glance

| | legacy-replicator | legacy-replicator-sbx | analytics-sync (shadow-mirror) |
|---|---|---|---|
| Language / runtime | Go, distroless static | same binary | Go, same module |
| Repo path | `services/analytics-sync/cmd/legacy-replicator` | same | `services/analytics-sync/cmd/shadow-mirror` |
| Dockerfile | `Dockerfile.replicator` | `Dockerfile.replicator` | `Dockerfile` |
| Container (staging) | `legacy-replicator` | `legacy-replicator-sbx` | `analytics-sync` (network alias `shadow-mirror`) |
| Host (staging) | app host | same | same |
| Ports (not published) | `:9104` `/healthz` `/metrics` | `:9114` | `:9103` |
| Source DB | legacy `packiot40`, SELECT-only user; password `.env` `LEGACY_DB_PASSWORD` | same | retired F1 `packiot` DB |
| Destination DB | `packiot_analytics`, direct to the DB host (not pgbouncer) | same | `shadow_go_port` + `packiot_analytics` |
| Tenant map | legacy ent 1 → analytics ent 3 | legacy ent 1 → 2000003 | same id |
| State | **running** | off unless `.env` `REPLICATE_SBX_ENABLED=true`; `SANDBOX_HOLD_ENABLED=true` | **idle** (`SHADOW_MIRROR_ENABLED=false`) |
| Limits | 128 MiB, 0.25 CPU | same | same |
| Depended on by | stream-engine PO compute, serving functions, operator app, front4, Superset | sandbox tenant consumers | nothing |
| Production (new stack) | not deployed (`compose.production.yml` has no replicator) | — | — |

## Inputs & outputs

| Kind | Object | Notes |
|---|---|---|
| Read (legacy) | `user_logs` | `WHERE id_enterprise = $SRC AND id_user_logs > cursor ORDER BY id_user_logs LIMIT BATCH_SIZE` |
| Read (legacy) | `production_orders`, `production_orders_runtime`, `products`, `product_families`, `clients` | PO resolution, reconciler, convergence, enrich |
| Read (legacy) | `equipment_events`, `equipment_events_man` | event resolution, base-event and manual-event reconcilers |
| Read (both) | `packml_register`, analytics `equipments` | equipment map at startup |
| Write | `core.production_orders` | inserts `ON CONFLICT (id_enterprise, id_order) DO NOTHING`; guarded, monotonic UPDATEs |
| Write | `gold.production_orders_runtime` | open/close/replace windows (overlap-guarded), `recalc_needed = true` |
| Write | `silver.equipment_events` | base events, classification UPDATEs, split segments |
| Write | `silver.equipment_events_man` | manual downtimes (the `public.*` shim was dropped on 2026-09-13) |
| Write | `core.products`, `core.product_families`, `core.clients` | only when enrich must create a missing dimension |
| Write | `ops.mirror_replay_cursor`, `ops.mirror_replay_dlq`, `ops.legacy_manual_event_link` | own bookkeeping |
| Call | `serving.downtime_events_resolved` refresh | for each UTC day an event reconciler touched |

## Internal design

```text
 main (cmd/legacy-replicator/main.go)
  ├─ BuildResolver()            once at boot: legacy id_equipment → analytics id_equipment
  ├─ Dispatcher                 user_logs.category → Handler (14; 12 when the manual
  │                             reconciler is on, it replaces the two manual handlers)
  ├─ Hold (sbx only)            ops.sandbox_hold_mode(DST) polled, 10 s cache
  ├─ go POReconciler            every RECONCILE_PO_INTERVAL_SEC: insert/finish, converge, enrich
  ├─ go ManualReconciler        every RECONCILE_MANUAL_EVENTS_INTERVAL_SEC
  ├─ go BaseReconciler          every RECONCILE_BASE_EVENTS_INTERVAL_SEC
  ├─ go DLQRetrier              every DLQ_RETRY_INTERVAL_SEC
  └─ Loop()                     poll → dispatch → DLQ on error → advance cursor, forever
```

### Id mapping (`internal/replicate/resolver.go`)

Legacy and analytics allocate ids independently, so ids are translated by **natural key**,
never copied:

| Entity | Rule |
|---|---|
| Enterprise | fixed `SRC_ENTERPRISE` → `DST_ENTERPRISE` |
| Equipment | shortest non-`/Admin/`, non-`/Status` `packml_topic`, first segment (enterprise name) stripped, uppercased: `C-PACK/SC/LINHAS/L5/BREYER` and `CPACK/SC/LINHAS/L5/BREYER` both become `SC/LINHAS/L5/BREYER`. Topics with an empty segment (`…/LINHAS//`) are ignored. Names are never used (not unique in CPACK). |
| Site / area | from the **analytics** `equipments` row, never from the payload |
| PO | legacy `id_production_order` → legacy `id_order` → analytics `(id_enterprise, id_order)` |
| Event | legacy `id_equipment_event` → legacy `(id_equipment, ts_event, ts_end, status)` → analytics row by exact ts, then overlap |

The map is built **once at startup**: equipment added on either side later stays
unresolved until the container restarts.

### Handlers (`internal/replicate/handlers.go`)

| `user_logs.category` | Effect in analytics |
|---|---|
| `downtime-event-created` | Insert base events into `silver.equipment_events` (`forced_creation_system=false`, `ON CONFLICT (id_equipment, ts_event) DO NOTHING`). Gated by `REPLICATE_BASE_EVENTS`. |
| `event-justified`, `event-edited` | UPDATE classification. Exact `(id_equipment, ts_event)` first, else the interval-overlap matcher. |
| `manual-event-created`, `manual-event-edited` | Insert / best-effort update `silver.equipment_events_man`. **Not registered** when `RECONCILE_MANUAL_EVENTS_ENABLED=true` (staging), so every mirrored row has provenance. |
| `event-splitted` | Segment 0 shrinks the matched base event; segments 1..N-1 are inserted with `forced_creation_system=true` (as legacy `downtimes-dao.ts::split`). |
| `order-created` | Insert PO, status 1. Unresolved equipment is an **error** (DLQ + retry), not a skip, so the PO is not silently lost. |
| `order-created-started`, `order-started` | Insert or start the PO (a never-run status-1 PO is first re-homed to the equipment it starts on; `ts_start` keeps the first start), then open a window on the PO's own equipment. |
| `order-stopped` | Close the window; status 3 (or 4 for a pause), `ts_end`, `production_real`. Monotonic: never moves an end backwards. |
| `order-changed` | Close the old PO; insert-and-start a new one, or start a pre-existing one (`shouldCreatePo=false`). |
| `order-time-changed` | UPDATE `ts_start` (the payload's end is ignored; convergence fixes it). |
| `order-replaced` | Move the runtime that was running at `ts_log` to the new PO; re-derive both headers from their windows (old PO → status 4 with what is left, or back to 1). |
| `order-status-changed` | Set `recalc_needed = true`. |

Handler contract: `ErrSkip` (malformed or not applicable) advances the cursor quietly; any
other error is counted, written to the DLQ, and the cursor still advances. A missing
destination table (SQLSTATE `42P01`) is logged and treated as success, so a partly
provisioned DB cannot wedge the loop (this is also how the dropped `public.equipment_events_man`
shim silently swallowed manual events from 2026-09-12; see Failure modes). An UPDATE that
touches zero rows increments `shadow_mirror_update_noop_total{table}` (a "replay gap").

### Runtime windows and the overlap guard (#1335)

A machine cannot run two POs at once: `gold.production_orders_runtime` has an exclusion
constraint on `(id_equipment, runtime_timerange)`. Opening a window runs three statements:

```sql
-- 1. close any open window on the equipment that started before ts
UPDATE gold.production_orders_runtime
   SET runtime_timerange = tstzrange(lower(runtime_timerange), $ts), recalc_needed = true
 WHERE id_equipment = $eq AND upper(runtime_timerange) IS NULL AND lower(runtime_timerange) < $ts;
-- 2. finish any other running PO on the equipment, ending it at ts
UPDATE core.production_orders SET status = 3, ts_end = $ts, recalc_needed = true
 WHERE id_equipment = $eq AND status = 2 AND NOT (<this PO>)
   AND (ts_start IS NULL OR ts_start <= $ts);
-- 3. insert [ts, ∞) only if NOTHING on this equipment overlaps it (open or closed, any PO)
INSERT INTO gold.production_orders_runtime (...) SELECT ... FROM core.production_orders po
 WHERE po.id_enterprise = $ent AND po.id_order = $ord
   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime x
                    WHERE x.id_equipment = po.id_equipment
                      AND x.runtime_timerange && tstzrange($ts, NULL));
```

Replay is not strictly chronological, so before 2026-09-20 (when step 3 only checked this
PO's own open window) the insert could fail with 23P01. The `&&` guard turns that into an
idempotent no-op. Stop/change UPDATEs carry `ts_start <= $ts_end` (no inverted range, 23514)
and `ts_end IS NULL OR ts_end <= $ts_end` (a late DLQ retry cannot reopen a later finish).

### Interval-overlap matcher

When the exact twin event is missing (the tee derived it at a slightly different time),
the same-`(equipment, status)` analytics event whose `[ts_event, COALESCE(ts_end, now())]`
overlaps the legacy window by ≥ `EVENT_MIN_OVERLAP_SEC` is picked, if its start is no
earlier than legacy start minus `EVENT_MAX_START_DRIFT_SEC` (a stale open event cannot
match everything). It is a port of mirror-worker-go's `translate.EquipmentEvent`.

### PO reconciler (`reconcile.go`, `reconcile_converge.go`, `enrich.go`)

Each pass reads legacy POs of `SRC_ENTERPRISE` that started, ended, were created or were
updated in the last `RECONCILE_PO_WINDOW_DAYS`, plus every `id_order` the twin holds as
started/ended in the window:

- **Missing in analytics** → insert the header from legacy (status, counters, times,
  `id_order_text`, notes; `recalc_needed = true`). Since 2026-10-09 this includes
  **available** POs created by the ERP/import path, which never reach `user_logs`.
- **Running in analytics, finished/paused in legacy** → close the window at legacy
  `ts_end` and set legacy's status.
- **Started PO without a runtime row** (#1555, 2026-10-02) → open one, overlap-guarded;
  a blocked insert is retried on a later pass.
- **Convergence** (#1674, 2026-10-09) — each rule moves the twin *toward* legacy and is a
  no-op once equal: *retime* (both finished → header times = legacy's), *revert* (legacy
  available, twin finished/paused → back to 1, re-checked just before writing), *windows*
  (both settled → twin windows become exactly legacy's `production_orders_runtime` rows in
  one transaction; any blocked insert rolls that PO back and is retried later).
- **Enrich** (#1452) — POs created in the last `RECONCILE_PO_ENRICH_WINDOW_DAYS` with NULL
  `id_product`/`id_client` get legacy's product, family and client, resolved by the unique
  natural keys (`nm_product`, `nm_product_family`, `nm_client`); a missing dimension is
  created, keeping legacy's id only when it is free and `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS=true`.
  Only NULL columns are filled.

### Base-event reconciler (`base_reconcile.go`, #1664)

On 2026-10-07 ~14:17 UTC the CPACK edge started publishing events on Pub/Sub to the
legacy oeecloud, which writes `equipment_events` without an audit row, so
`downtime-event-created` stopped and every machine's last STOP stayed open on the twin.
Each pass now reads legacy `forced_creation_system=false` rows with
`ts_event >= now - RECONCILE_BASE_EVENTS_LOOKBACK_HOURS`, maps them through the resolver
and **only inserts** the ones the twin lacks (`ON CONFLICT DO NOTHING`, and skipped when
the twin has an event within ±1 s, because the replay carries milliseconds and legacy
whole seconds). `ts_end` stays the stream-engine closer's job. Requires
`REPLICATE_BASE_EVENTS=true`.

### Manual-event reconciler (`manual_reconcile.go`, #1504)

Mirrors legacy `equipment_events_man` → `silver.equipment_events_man` within
`RECONCILE_MANUAL_EVENTS_LOOKBACK_DAYS`: dedupe legacy rows by the analytics unique key
`(id_equipment, ts_event)`, then update changed rows, move a linked row whose start was
edited, insert new ones, and delete only rows it owns (`ops.legacy_manual_event_link`)
that vanished from legacy, at most `RECONCILE_MANUAL_EVENTS_MAX_DELETES` per pass (over the
cap, deletes are skipped and logged). Unlinked rows (new-stack authored) are never touched.
One transaction per pass.

### Sandbox hold (`hold.go`)

Only the sbx instance sets `SANDBOX_HOLD_ENABLED`. It reads `ops.sandbox_hold_mode(2000003)`:
in **session** mode (a person is testing on the sandbox) the loop advances its cursor
without applying, because the heal at the end of the grace period reflects the source's
current state; in **healing** mode the loop pauses (no fetch, no advance) so actions
arriving mid-heal are replayed afterwards. In both modes the reconcilers and the DLQ
retrier skip their passes. Errors fail open (not held). See
[Simulators and twins](simulators-and-twins.md).

### DLQ (`dlq.go`)

`ops.mirror_replay_dlq` (shared with mirror-worker-go's history, keyed by `source`). The
retrier picks rows for its own `source` with `retry_attempts < DLQ_RETRY_MAX_ATTEMPTS`
whose backoff (`2^retry_attempts` minutes since `last_retry_at`) has elapsed, re-reads the
legacy `user_logs` row and re-dispatches it. Success or a clean skip deletes the row; a
vanished legacy row is retired at the cap.

### shadow-mirror (`cmd/shadow-mirror`, `internal/replay`)

The original ADR-0013 in-instance replayer of the F1 `packiot.user_logs`. Its source froze
around 2026-08-18; it runs idle and only serves `/healthz` and `/metrics`. Do not build on it.

## Configuration

legacy-replicator (`internal/replicate/config.go`). Staging values from `compose.staging.yml`.

| Variable | Default | Staging (ent 3 / sbx) | Effect |
|---|---|---|---|
| `REPLICATE_ENABLED` | `false` | `true` / `${REPLICATE_SBX_ENABLED:-false}` | Master switch; off = idle HTTP only |
| `LEGACY_DB_HOST` / `_PORT` / `_USER` / `_NAME` | legacy host / 5432 / SELECT-only user / `packiot40` | same | Source; never written |
| `LEGACY_DB_PASSWORD` | — | `.env` | Required when enabled; boot refuses without it |
| `DEST_DB_HOST` / `_PORT` / `_USER` / `_NAME` | DB host / 5432 / `postgres` / `packiot_analytics` | DB host, `${POSTGRES_USER}` | Destination |
| `DEST_DB_PASSWORD` | — | `${POSTGRES_PASSWORD}` | Required when enabled |
| `SRC_ENTERPRISE` / `DST_ENTERPRISE` | `1` / `3` | `1`→`3`; `1`→`2000003` | Tenant map |
| `BACKFILL_SINCE_DAYS` | `60` | `60` | Cold-start history depth |
| `BACKFILL_SINCE` | — | — | `YYYY-MM-DD` or RFC3339; overrides days on cold start |
| `REPLICATE_BASE_EVENTS` | `true` | `true` | Replay and reconcile base PLC events |
| `CURSOR_SOURCE` | `legacy-cpack` | `legacy-cpack` / `legacy-sbxcpack` | Cursor + DLQ key; must differ per instance |
| `POLL_INTERVAL_MS` | `3000` | `3000` | Sleep when a poll returns nothing |
| `BATCH_SIZE` | `200` | `200` | Rows per poll |
| `HEALTH_PORT` | `9104` | `9104` / `9114` | HTTP port |
| `HEALTHCHECK_MAX_AGE_SEC` | `0` (off) | `600` | `/healthz` 503 when no successful poll for this long |
| `LOG_LEVEL` | `info` | `info` | |
| `SANDBOX_HOLD_ENABLED` | `false` | unset / `true` | Sandbox hold gate |
| `RECONCILE_PO_ENABLED` / `_INTERVAL_SEC` / `_WINDOW_DAYS` | `false` / 300 / 14 | `true` / 300 / 14 | PO reconciler + convergence |
| `RECONCILE_PO_ENRICH_ENABLED` / `_WINDOW_DAYS` | `false` / 14 | `true` / 120 | Enrich pass (window by analytics `ts_creation`) |
| `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` | `true` | default / `false` | `false` for any id-offset tenant |
| `RECONCILE_BASE_EVENTS_ENABLED` / `_INTERVAL_SEC` / `_LOOKBACK_HOURS` | `false` / 120 / 72 | `true` / 120 / 96 | Base-event reconciler |
| `RECONCILE_BASE_EVENTS_REFRESH_SERVING` | `true` | default | Refresh `serving.downtime_events_resolved` for touched days |
| `RECONCILE_MANUAL_EVENTS_ENABLED` / `_INTERVAL_SEC` / `_LOOKBACK_DAYS` | `false` / 300 / 35 | `true` / 300 / 35 | Manual-event reconciler (replaces the manual handlers) |
| `RECONCILE_MANUAL_EVENTS_MAX_DELETES` | `50` | `50` | Delete cap per pass |
| `RECONCILE_MANUAL_EVENTS_REFRESH_SERVING` | `true` | `true` | Serving refresh for touched days |
| `EVENT_MIN_OVERLAP_SEC` / `EVENT_MAX_START_DRIFT_SEC` | `30` / `600` | default | Overlap matcher |
| `DLQ_CAPTURE_ENABLED` / `DLQ_RETRY_ENABLED` | `true` / `true` | default | DLQ capture and retrier |
| `DLQ_RETRY_INTERVAL_SEC` / `_MAX_ATTEMPTS` / `_BATCH_SIZE` | `120` / `5` / `100` | default | Retrier tuning |

shadow-mirror (`internal/config/config.go`): `SHADOW_MIRROR_ENABLED` (default `false`),
`PG_DB_NAME` (`packiot`), `PG_ANALYTICS_DB_NAME` (`packiot_analytics`), `DB_HOST`/`DB_PORT`/
`DB_USER`/`DB_PASSWORD`, `POLL_INTERVAL_MS` (2000), `BATCH_SIZE` (100), `MAX_RETRIES` (5),
`HEALTH_PORT` (9103), `LOG_LEVEL`. Idle (staging and dev) it opens no DB connection, so compose gives
it **no DB credentials and no `env_file`** (it used to carry the admin `POSTGRES_*` and the whole `.env`);
`scripts/ci/check-db-least-priv.py` keeps it that way. Enabled, it needs both `DB_USER` and
`DB_PASSWORD` (no default user, so never the admin by accident) and a least-privilege role of its own.

## Data & invariants

- **Legacy is read-only.** Every write, the cursor and the DLQ live in the analytics DB.
- **Idempotent by natural key**: POs by `(id_enterprise, id_order)`, events by
  `(id_equipment, ts_event)`; guarded UPDATEs; reconcile rules are no-ops once equal. A
  cursor rewind is safe.
- **Monotonic**: the cursor only moves forward (and advances on failure, the DLQ keeps the
  row); PO ends never move backwards.
- **One running PO per equipment**: a start finishes the previous PO; window inserts are
  overlap-guarded against every other PO.
- **Never overwrite new-stack data**: enrich fills NULLs only; the manual reconciler
  deletes only rows it linked.
- **Tenant isolation**: all writes use the resolver's analytics ids under `DST_ENTERPRISE`;
  two instances must use different `CURSOR_SOURCE` values.
- **Base events are PLC-born** (`forced_creation_system=false`); split segments are
  human-born (`true`).

## Observability

| Signal | Meaning |
|---|---|
| `shadow_mirror_dispatched_total{category}` / `_skipped_total` / `_failed_total` | Per-category replay outcomes (names kept from the shadow-mirror era; `skipped{category="sandbox-hold"}` on the sbx) |
| `shadow_mirror_update_noop_total{table}` | Zero-row UPDATEs = replay gaps. Alert `ReplicatorReplayGaps` (> 0 for 30 min, job `legacy-replicator`) |
| `shadow_mirror_cursor` | Last replayed `id_user_logs` |
| `legacy_replicator_reconcile_{inserted,finished,unresolved}_total` | PO reconciler |
| `legacy_replicator_reconcile_enriched_total`, `_enrich_skipped_total{reason}` | Enrich |
| `legacy_replicator_base_events_total`, `legacy_replicator_manual_events_total` | Event reconcilers (by action) |
| `legacy_replicator_dlq_depth`, `legacy_replicator_dlq_retried_total{outcome}` | DLQ health |
| Alert `ShadowMirrorFailures` | `increase(shadow_mirror_failed_total[15m]) > 0` |
| `/healthz` | 200 while the loop polls; 503 after `HEALTHCHECK_MAX_AGE_SEC` without a successful poll |

Log lines worth grepping: `resolver built`, `unresolved legacy equipment`, `dispatch failed`,
`event-classified: no twin base event`, `PO reconcile: window convergence blocked by a
neighbour`, `base-event reconcile pass done`, `manual-event reconcile pass done`,
`manual-event reconcile: deletes SKIPPED by guard`, `sandbox hold state`.

Prometheus scrapes `legacy-replicator:9104` and `analytics-sync:9103`; the sbx instance is
**not** scraped (no job in `monitoring/prometheus/prometheus.yml`).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| DLQ 23P01 flood (2026-09-20) | 1,374 DLQ rows, stale windows | open-window guard ignored other POs / closed windows | #1335 `&&` guard; re-arm and drain the DLQ |
| "Fix merged" but nothing changed (2026-09-20) | same errors after deploy | the PRs held only tests + a plan doc | check `git show origin/staging:<file>` and the container's creation time before draining |
| POs with no runtime window (2026-09-23, again 2026-10-02) | POs with `ts_start` but zero production | start replayed before the PO existed, or unresolved payload equipment | #1389; reconciler opens missing windows (#1555) |
| Manual events silently dropped (2026-09-12 → fix) | twin manual downtimes stop | handlers wrote the dropped `public.equipment_events_man`; `42P01` is fail-open | handlers write `silver.*`; manual reconciler (#1504) |
| Stops never close on the twin (from 2026-10-07) | machines frozen in STOP | CPACK edge moved events to Pub/Sub; no audit rows | base-event reconciler (#1664) |
| PO header/window drift vs legacy (found 2026-10-09) | wrong start/end, twin-only runs, missing windows | re-starts, time edits and reverts the replay cannot express | convergence (#1674) |
| Client / product blank (2026-09-25) | 0 of 1,285 POs linked | legacy sets them outside `user_logs` | enrich (#1452/#1453) |
| Sandbox lead machines unresolved | sandbox downtimes dropped for 7 lines | junk topics like `SANDBOX_CPACK/SC/LINHAS//` won the shortest-topic pick | empty-segment guard |
| Loop wedged / legacy unreachable | container unhealthy, cursor flat | network or legacy outage | check legacy reachability from the app host; the loop resumes by itself |

## Operating it

**Deploy / restart.** All three containers build from `services/analytics-sync` in the
normal staging deploy (`deploy-staging.yml`). To restart one, use the compose labels on the
running container (project `stack`, files from `com.docker.compose.project.config_files`):
`docker compose -p stack -f <files> up -d --no-deps legacy-replicator`. Restart after any
change to `packml_register` or equipment on either side (the resolver is built at boot).

**Drain a DLQ after a fix:**

1. Confirm the fix is in the *merged* code and the container was recreated after the merge.
2. `SELECT category, left(error,80), count(*) FROM ops.mirror_replay_dlq WHERE source='legacy-cpack' GROUP BY 1,2;`
3. Re-arm: `UPDATE ops.mirror_replay_dlq SET retry_attempts = 0, last_retry_at = NULL WHERE source = 'legacy-cpack';`
4. Watch `legacy_replicator_dlq_depth` fall (100 rows per 120 s pass by default).

**Replay a window again** (safe, writes are idempotent): stop the container, set
`UPDATE ops.mirror_replay_cursor SET last_log_id = <id> WHERE source = 'legacy-cpack';`,
start it. For PO headers prefer the reconciler (widen `RECONCILE_PO_WINDOW_DAYS` temporarily).

**Deeper backfill on a fresh tenant**: delete the cursor row for the source and set
`BACKFILL_SINCE=YYYY-MM-DD`.

**Unsafe**: two instances on one `CURSOR_SOURCE`; `KEEP_LEGACY_IDS=true` for an id-offset
tenant; enabling `shadow-mirror`; raising the manual delete cap without reading the skipped
deletes; any write to the legacy DB.

## Tests

`cd services/analytics-sync && go test ./...` (CI: `.github/workflows/go-services.yml`).
`internal/replicate/` has unit and golden tests per part: `handlers_test.go`,
`lifecycle_golden_test.go`, `resolver_test.go`, `reconcile_test.go`,
`reconcile_converge_test.go` + `_golden_test.go`, `base_reconcile_test.go` + `_golden_test.go`,
`manual_reconcile_test.go`, `enrich_test.go`, `hold_test.go`, `dlq_test.go`. Most are
SQL-shape and pure-planning tests; there is no live-DB integration test.

## Source map

| Path | What's there |
|---|---|
| `services/analytics-sync/README.md` | How to build, run and change it |
| `services/analytics-sync/cmd/legacy-replicator/main.go` | Wiring: pools, resolver, handlers, reconcilers, DLQ retrier, HTTP |
| `services/analytics-sync/internal/replicate/config.go` | Every env var and default |
| `services/analytics-sync/internal/replicate/loop.go`, `cursor.go` | Poll → dispatch → DLQ → cursor; cold-start seeding |
| `services/analytics-sync/internal/replicate/resolver.go` | Base-topic equipment map |
| `services/analytics-sync/internal/replicate/handlers.go` | Handlers, overlap matcher, runtime-window SQL |
| `services/analytics-sync/internal/replicate/reconcile.go`, `reconcile_converge.go`, `enrich.go` | PO reconciler, convergence, enrich |
| `services/analytics-sync/internal/replicate/base_reconcile.go`, `manual_reconcile.go` | Event reconcilers |
| `services/analytics-sync/internal/replicate/hold.go`, `dlq.go` | Sandbox hold gate; DLQ and retrier |
| `services/analytics-sync/internal/metrics/metrics.go`, `internal/health/health.go` | Metrics; heartbeat `/healthz` |
| `services/analytics-sync/cmd/shadow-mirror/`, `internal/replay/` | Idle in-instance replayer |
| `compose.staging.yml` (`analytics-sync`, `legacy-replicator`, `legacy-replicator-sbx`) | Deployment and staging values |
| `monitoring/prometheus/prometheus.yml`, `rules.yml` | Scrape jobs, `ReplicatorReplayGaps`, `ShadowMirrorFailures` |
| `docs/adr/0013-shadow-mirror-service.md` | Design decision |
