---
title: analytics-sync (legacy-replicator and shadow-mirror)
layer: 3
owner_area: legacy-bridge
last_verified: 2026-09-28
---
# analytics-sync (legacy-replicator and shadow-mirror)

> **Layer 3 · Components** — the Go module that replays operator actions into the analytics
> DB: the live `legacy-replicator` (legacy `packiot40` → staging) and the idle
> `shadow-mirror`. For whoever debugs a missing PO or downtime on the CPACK twin.
> Up: [Legacy bridge](../subsystems/legacy-bridge.md)

## Responsibility

Make the staging analytics DB reflect, within seconds, every PO and downtime action that
CPACK's operators perform on the legacy platform, by re-applying each legacy audit row
(`user_logs`) idempotently under the analytics tenant, then closing the gaps the audit
trail cannot see (reconciler, enrich pass). It never computes OEE and never writes to the
legacy DB.

## At a glance

| | legacy-replicator | legacy-replicator-sbx | analytics-sync (shadow-mirror) |
|---|---|---|---|
| Language / runtime | Go 1.25, distroless static | same binary | Go, same module |
| Repo path | `services/analytics-sync/cmd/legacy-replicator` | same | `services/analytics-sync/cmd/shadow-mirror` |
| Image / Dockerfile | `Dockerfile.replicator` | `Dockerfile.replicator` | `Dockerfile` |
| Container (staging) | `legacy-replicator` | `legacy-replicator-sbx` | `analytics-sync` (alias `shadow-mirror`) |
| Host (staging) | app host `i-06c9547a2c7091ab7` | same | same |
| Ports | `:9104` `/healthz` `/metrics` (not published) | `:9114` | `:9103` |
| Source DB | legacy `packiot40`, SELECT-only user, password from Secrets Manager `databaseCredentials` via `.env` `LEGACY_DB_PASSWORD` | same | staging `packiot` (F1) |
| Destination DB | `packiot_analytics`, direct to the DB host (not pgbouncer) | same | `shadow_go_port` schema + `packiot_analytics.public` |
| Tenant map | legacy ent 1 → analytics ent 3 | legacy ent 1 → 2000003 | same id |
| State | **running** | compose default off; `.env` `REPLICATE_SBX_ENABLED=true` turns it on | **idle** (`SHADOW_MIRROR_ENABLED=false`) |
| Limits | 128 MiB, 0.25 CPU | same | same |
| Depends on | legacy DB reachability, analytics DB | same | — |
| Depended on by | stream-engine PO runtime, serving functions, operator app, front4, Superset | sandbox tenant consumers | nothing (retired) |
| Production (new stack) | not deployed (`compose.production.yml` has no bridge) | — | — |

## Inputs & outputs

| Kind | Object | Notes |
|---|---|---|
| Read (legacy) | `user_logs` | `WHERE id_enterprise = $SRC AND id_user_logs > cursor ORDER BY id_user_logs LIMIT BATCH_SIZE` |
| Read (legacy) | `production_orders`, `products`, `product_families`, `clients` | natural-key resolution, reconciler, enrich |
| Read (legacy) | `equipment_events`, `equipment_events_man` | resolve the legacy event behind a justify/split |
| Read (both) | `packml_register`, analytics `equipments` | build the equipment map at startup |
| Write | `core.production_orders` | insert `ON CONFLICT (id_enterprise, id_order) DO NOTHING`; guarded UPDATEs |
| Write | `gold.production_orders_runtime` | open/close `[ts, ∞)` windows, set `recalc_needed = true` |
| Write | `silver.equipment_events` | base events, classification UPDATEs, split segments |
| Write | `public.equipment_events_man` | manual downtimes |
| Write | `core.products`, `core.product_families`, `core.clients` | only when enrich must create a missing dimension |
| Write | `ops.mirror_replay_cursor`, `ops.mirror_replay_dlq` | created on demand (schema-qualified to `ops`) |

## Internal design

```text
 main (cmd/legacy-replicator/main.go)
  ├─ BuildResolver()         once at startup: legacy id_equipment → analytics id_equipment
  ├─ Dispatcher              category → Handler (14 registered)
  ├─ go POReconciler.RunForever   pass at boot, then every RECONCILE_PO_INTERVAL_SEC
  │                               └─ runEnrich() at the end of each pass
  ├─ go DLQRetrier.RunForever     every DLQ_RETRY_INTERVAL_SEC
  └─ Loop()                  poll → dispatch → DLQ on error → advance cursor, forever
```

### Id mapping (`internal/replicate/resolver.go`)

Legacy and analytics allocate ids independently, so every id is translated by a
**natural key**, never copied:

| Entity | Rule |
|---|---|
| Enterprise | fixed `SRC_ENTERPRISE` → `DST_ENTERPRISE` |
| Equipment | shortest non-`/Admin/`, non-`/Status` `packml_topic` per equipment, first segment (enterprise name) stripped, uppercased: `C-PACK/SC/LINHAS/L5/BREYER` and `CPACK/SC/LINHAS/L5/BREYER` both become `SC/LINHAS/L5/BREYER`. Topics with an empty segment (`…/LINHAS//`) are ignored. Names are not unique in CPACK, so names are never used. |
| Site / area | taken from the **analytics** `equipments` row, never from the payload |
| PO | legacy surrogate `id_production_order` → legacy `id_order` (SELECT on legacy) → analytics `(id_enterprise, id_order)` |
| Event | legacy `id_equipment_event` → legacy `(id_equipment, ts_event, ts_end, status)` → analytics row by exact ts, then overlap |

The map is built **once at startup**. Equipment added to either side later stays unresolved
until the container restarts.

### Handlers (`internal/replicate/handlers.go`)

| `user_logs.category` | Effect in analytics |
|---|---|
| `downtime-event-created` | Insert base events into `silver.equipment_events` with `forced_creation_system=false`, `ON CONFLICT (id_equipment, ts_event) DO NOTHING`. `id_equipment_event` is synthesised (`ts_ms*1000 + equip%1000`); it has no unique meaning. Gated by `REPLICATE_BASE_EVENTS`. |
| `event-justified`, `event-edited` | UPDATE classification (category, subcategory, machine, notes, change-over, planned, idle). Exact `(id_equipment, ts_event)` first; else interval-overlap match (below). |
| `manual-event-created` | Insert into `equipment_events_man` (omits `id_equipment_event`, an IDENTITY). |
| `manual-event-edited` | Best-effort UPDATE keyed on the current legacy `ts_event`; a moved start time is a counted no-op. |
| `event-splitted` | Segment 0 shrinks the matched base event in place; segments 1..N-1 are inserted as new `equipment_events` rows with `forced_creation_system=true` (matches legacy `downtimes-dao.ts::split`). |
| `order-created` | Insert PO with status 1. Unresolved equipment returns an **error** (DLQ + retry), not a skip, so the PO is not silently lost. |
| `order-created-started` | Open runtime window, insert PO with status 2 and `ts_start`. |
| `order-started` | UPDATE status 2 + `ts_start`; open the window on the PO's **own** `id_equipment` (PR #1389). |
| `order-stopped` | Close window; UPDATE status 3 (or 4 for `stopType=pause`), `ts_end`, `production_real`. |
| `order-changed` | Close the old PO (status, `ts_end`, `production_final`); if `shouldCreatePo`, insert and open the new one. |
| `order-time-changed` | UPDATE `ts_start`. |
| `order-replaced`, `order-status-changed` | Set `recalc_needed = true`. |

Contract of a handler: `ErrSkip` (malformed or not applicable) advances the cursor quietly;
any other error is counted, written to the DLQ, and the cursor still advances. A missing
destination table (SQLSTATE `42P01`) is logged and treated as success so a partly
provisioned DB cannot wedge the loop. An UPDATE that touches zero rows increments
`shadow_mirror_update_noop_total{table}` (a "replay gap").

### Runtime windows and the overlap guard (#1335)

A machine cannot run two POs at once: `gold.production_orders_runtime` has an exclusion
constraint on `(id_equipment, runtime_timerange)`. Opening a window runs three statements:

```sql
-- 1. close any open window on the equipment that started before ts
UPDATE gold.production_orders_runtime
   SET runtime_timerange = tstzrange(lower(runtime_timerange), $ts), recalc_needed = true
 WHERE id_equipment = $eq AND upper(runtime_timerange) IS NULL
   AND lower(runtime_timerange) < $ts;
-- 2. finish any other running PO on the equipment
UPDATE core.production_orders SET status = 3
 WHERE id_equipment = $eq AND status = 2 AND NOT (<this PO>);
-- 3. insert [ts, ∞) only if NOTHING on this equipment overlaps it (open OR closed, any PO)
INSERT INTO gold.production_orders_runtime (...) SELECT ... FROM core.production_orders po
 WHERE po.id_enterprise = $ent AND po.id_order = $ord
   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime x
                    WHERE x.id_equipment = po.id_equipment
                      AND x.runtime_timerange && tstzrange($ts, NULL));
```

Before 2026-09-20 step 3 only checked for an open window of *the same PO*. Legacy replay is
not strictly chronological, so a closed window or another PO's window could already overlap
and the insert failed with 23P01. The `&&` guard turns that into an idempotent no-op.
PO stop/change UPDATEs also carry `AND (ts_start IS NULL OR ts_start <= $ts_end)` so an
out-of-order stop never writes an inverted range (23514).

### Interval-overlap matcher

When the exact twin event is missing (the co-tee derived it at a slightly different time),
`findTwinEventByOverlap` picks the same-`(equipment, status)` analytics event whose
`[ts_event, COALESCE(ts_end, now())]` overlaps the legacy event's window by at least
`EVENT_MIN_OVERLAP_SEC`, and whose start is no earlier than legacy start minus
`EVENT_MAX_START_DRIFT_SEC` (so a stale open event from days ago cannot match everything).
It is a port of mirror-worker-go's `translate.EquipmentEvent`. Exact matches cover about 96%
of live traffic (2026-08-27 measurement).

### PO reconciler (`reconcile.go`)

Every `RECONCILE_PO_INTERVAL_SEC` (300 s) it reads legacy POs with `ts_start` or `ts_end`
inside the last `RECONCILE_PO_WINDOW_DAYS` (14):

- **Missing in analytics** → insert the header from legacy's row (status, counters, times,
  `id_order_text` as name, notes) with `recalc_needed = true`. A status-2 PO is skipped if
  the equipment already has a running PO (unique partial index). **No runtime window is
  created** for these (a blind insert would hit the exclusion constraint).
- **Running in analytics, finished/paused in legacy** → close the window at legacy `ts_end`
  and set the legacy status.

### Enrich pass (`enrich.go`, PR #1452)

Runs at the end of each reconciler pass. Candidates: analytics POs created in the last
`RECONCILE_PO_ENRICH_WINDOW_DAYS` with NULL `id_product` or `id_client`. For each, legacy's
product (name, code, family name) and client name are resolved in analytics by the unique
natural keys `(id_enterprise, nm_product)`, `(id_enterprise, nm_client)`,
`(id_enterprise, nm_product_family)`. Ids are never trusted alone: both sequences sit at
legacy's max, so the next native row and the next legacy row could share an id while
meaning different things. A missing dimension is created, keeping legacy's id only when it
is free **and** `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS=true` (then the sequence is moved past
it). One set-based UPDATE fills only NULL columns (`COALESCE`).

### DLQ (`dlq.go`)

`ops.mirror_replay_dlq(id, source, source_log_id, category, subcategory, payload, error,
retry_attempts, last_retry_at, created_at)`. The retrier selects rows for its own `source`
with `retry_attempts < DLQ_RETRY_MAX_ATTEMPTS` whose backoff (`2^retry_attempts` minutes
since `last_retry_at`) has elapsed, re-reads the legacy `user_logs` row, and re-dispatches it
through the same handlers. Success (or a clean skip) deletes the row; failure bumps
`retry_attempts`; a vanished legacy row is retired at the cap.

### shadow-mirror (`cmd/shadow-mirror`, `internal/replay`)

The original ADR-0013 in-instance replayer: it polls staging's own F1 `packiot.user_logs`
(cursor source `shadow-mirror`) and applies 13 handlers to both `shadow_go_port.*` and
`packiot_analytics.public.*`. After the F1 plane was retired it had nothing to read (source
froze around 2026-08-18) and it is kept idle. The legacy-replicator supersedes it for CPACK.
Do not build on it.

## Configuration

legacy-replicator (`internal/replicate/config.go`). Staging values from `compose.staging.yml`.

| Variable | Default | Staging (ent 3 / sbx) | Effect |
|---|---|---|---|
| `REPLICATE_ENABLED` | `false` | `true` / `${REPLICATE_SBX_ENABLED:-false}` | Master switch |
| `LEGACY_DB_HOST` / `_PORT` / `_USER` / `_NAME` | legacy host / 5432 / SELECT-only user / `packiot40` | same | Source; never written |
| `LEGACY_DB_PASSWORD` | — | from `.env` (Secrets Manager `databaseCredentials`) | Required when enabled; boot refuses without it |
| `DEST_DB_HOST` / `_PORT` / `_USER` / `_NAME` | DB host / 5432 / `postgres` / `packiot_analytics` | DB host direct | Destination |
| `DEST_DB_PASSWORD` | — | `${POSTGRES_PASSWORD}` | Required when enabled |
| `SRC_ENTERPRISE` / `DST_ENTERPRISE` | `1` / `3` | `1`→`3`; `1`→`2000003` | Tenant map |
| `BACKFILL_SINCE_DAYS` | `60` | `60` | Cold-start history depth |
| `BACKFILL_SINCE` | — | — | `YYYY-MM-DD` or RFC3339; overrides days on cold start |
| `REPLICATE_BASE_EVENTS` | `true` | `true` | Insert base PLC events |
| `CURSOR_SOURCE` | `legacy-cpack` | `legacy-cpack` / `legacy-sbxcpack` | Cursor + DLQ key; must differ per instance |
| `POLL_INTERVAL_MS` | `3000` | `3000` | Sleep when a poll returns nothing |
| `BATCH_SIZE` | `200` | `200` | Rows per poll |
| `HEALTH_PORT` | `9104` | `9104` / `9114` | HTTP port |
| `HEALTHCHECK_MAX_AGE_SEC` | `0` (off) | `600` | `/healthz` 503 when no successful poll for this long |
| `LOG_LEVEL` | `info` | `info` | |
| `RECONCILE_PO_ENABLED` | `false` | `true` | PO reconciler |
| `RECONCILE_PO_INTERVAL_SEC` | `300` | `300` | |
| `RECONCILE_PO_WINDOW_DAYS` | `14` | `14` | Legacy activity lookback |
| `RECONCILE_PO_ENRICH_ENABLED` | `false` | `true` | Enrich pass |
| `RECONCILE_PO_ENRICH_WINDOW_DAYS` | `14` | `120` | By analytics `ts_creation` |
| `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` | `true` | `true` / `false` | `false` for any id-offset tenant |
| `EVENT_MIN_OVERLAP_SEC` | `30` | default | Overlap matcher |
| `EVENT_MAX_START_DRIFT_SEC` | `600` | default | Overlap matcher |
| `DLQ_CAPTURE_ENABLED` | `true` | default | Write failures to the DLQ |
| `DLQ_RETRY_ENABLED` | `true` | default | Run the retrier |
| `DLQ_RETRY_INTERVAL_SEC` | `120` | default | |
| `DLQ_RETRY_MAX_ATTEMPTS` | `5` | default | |
| `DLQ_RETRY_BATCH_SIZE` | `100` | default | |

shadow-mirror (`internal/config/config.go`): `SHADOW_MIRROR_ENABLED` (default `false`),
`PG_DB_NAME` (`packiot`), `PG_ANALYTICS_DB_NAME` (`packiot_analytics`, empty = only
`shadow_go_port`), `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD`, `POLL_INTERVAL_MS` (2000),
`BATCH_SIZE` (100), `MAX_RETRIES` (5), `HEALTH_PORT` (9103), `LOG_LEVEL`. `PG_SECRET_ID` and
`AWS_REGION` are read but Secrets Manager fetch was never implemented (creds come from env).

## Data & invariants

- **Legacy is read-only.** Every write and the cursor live in the analytics DB.
- **Idempotent by natural key.** POs by `(id_enterprise, id_order)`; events by
  `(id_equipment, ts_event)`; guarded UPDATEs. Re-replaying a window changes no counts
  (checked when the service was introduced), which makes a cursor rewind safe.
- **Cursor only moves forward** (`UPDATE … WHERE last_log_id < $1`) and advances even on
  failure; failures are preserved in the DLQ instead.
- **One running PO per equipment** is preserved: starts finish the previous PO; the
  reconciler skips a running insert that would collide.
- **Never overwrite new-stack edits** in enrich (NULL-fill only).
- **Tenant isolation**: all writes use the resolver's analytics ids under `DST_ENTERPRISE`.
  Two instances must use different `CURSOR_SOURCE` values.
- **Base events are PLC-born** (`forced_creation_system=false`); split segments and manual
  events are human-born (`true`). `serving.v_operator_po_details_3` counts only `false`.

## Observability

| Signal | Meaning |
|---|---|
| `shadow_mirror_dispatched_total{category}` / `_skipped_total` / `_failed_total` | Per-category outcomes (metric names kept from the shadow-mirror era) |
| `shadow_mirror_update_noop_total{table}` | Zero-row UPDATEs = replay gaps. Alert `ReplicatorReplayGaps` (> 0 for 30 min, job `legacy-replicator`) |
| `shadow_mirror_cursor` | Last replayed `id_user_logs` |
| `legacy_replicator_reconcile_{inserted,finished,unresolved}_total` | Reconciler outcomes |
| `legacy_replicator_reconcile_enriched_total`, `_enrich_skipped_total{reason}` | Enrich outcomes |
| `legacy_replicator_dlq_depth`, `legacy_replicator_dlq_retried_total{outcome}` | DLQ health (`succeeded`/`failed`/`gone`) |
| Alert `ShadowMirrorFailures` | `increase(shadow_mirror_failed_total[15m]) > 0` (any job) |
| `/healthz` | 200 while the loop polls successfully; 503 after `HEALTHCHECK_MAX_AGE_SEC` without a poll (Prometheus `up` cannot see a wedged loop) |

Log lines worth grepping: `resolver built` (mapped / unresolved counts at boot),
`unresolved legacy equipment`, `dispatch failed`, `event-classified: no twin base event`,
`PO reconcile pass done`, `DLQ retry pass done`.

Prometheus scrapes `legacy-replicator:9104` and `analytics-sync:9103`. The sbx instance is
**not** scraped (no job in `monitoring/prometheus/prometheus.yml`).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| DLQ 23P01 flood (2026-09-20) | 1,374 DLQ rows, runtime windows stale | Per-PO open-window guard ignored other POs / closed windows under out-of-order replay | PR #1335 `&&` guard; reset and drain the DLQ (below) |
| "Fix merged" but nothing changed (2026-09-20) | Same errors after deploy | PRs #1332/#1333 contained only tests + a plan doc | Check `git show origin/staging:<file>` and the container's creation time before draining |
| 58% of POs without runtime rows (found 2026-09-23) | POs with `ts_start` but no production attributed | `order-started` opened the window only if the payload equipment resolved | PR #1389 + backfill migration `t-cpack-backfill-po-runtime-windows` |
| Whole POs missing | Legacy has more POs than analytics | `order-created` used to `ErrSkip` unresolved equipment | Now errors into the DLQ; restart after fixing `packml_register`, then let the retrier drain |
| Client / Product blank (2026-09-25) | 0 of 1,285 September POs linked | Legacy sets them outside `user_logs` | Enrich pass #1452 / #1453 |
| Operator PO downtime 0 (2026-09-25) | `v_operator_po_details_3` shows 0 | Base events written `forced_creation_system=true` | Writer fixed (#1455), 256,306 rows re-flagged from legacy |
| Sandbox lead machines unresolved | Downtimes for 7 CPACK lead machines dropped on 2000003 | Junk topics like `SANDBOX_CPACK/SC/LINHAS//` won the shortest-topic pick | Empty-segment guard in `hasEmptySegment` |
| Manual events look like "pollution" | `equipment_events_man` 100% `forced_creation_system=true` on the twin | That flag bypasses the dedup trigger for replicated manual rows; they are real operator downtimes | Do not delete (see `docs/audits/eem-forced-flag-not-pollution.md`) |
| Loop wedged / legacy unreachable | Container unhealthy, cursor flat | Network or legacy outage | Check legacy reachability from the app host; the loop resumes by itself |

## Operating it

**Deploy / restart.** Both instances build from `services/analytics-sync` in the normal
staging deploy (`deploy-staging.yml`). To restart one without touching the stack, use the
compose labels on the running container (project `stack`, files from
`com.docker.compose.project.config_files`) and run
`docker compose -p stack -f <files> up -d --no-deps legacy-replicator`. Restart after any
change to `packml_register` or equipment on either side (the resolver is built at boot).

**Drain a DLQ after a fix** (the 2026-09-20 procedure):

1. Confirm the fix is in the *merged* code and the container was recreated after the merge.
2. Look at what is stuck:
   `SELECT category, left(error,80), count(*) FROM ops.mirror_replay_dlq WHERE source='legacy-cpack' GROUP BY 1,2;`
3. Re-arm exhausted rows:
   `UPDATE ops.mirror_replay_dlq SET retry_attempts = 0, last_retry_at = NULL WHERE source = 'legacy-cpack';`
4. Watch `legacy_replicator_dlq_depth` fall (100 rows per 120 s pass by default) and the
   `DLQ retry pass done` log lines.

**Replay a window again.** Safe because writes are idempotent: stop the container, set
`UPDATE ops.mirror_replay_cursor SET last_log_id = <id> WHERE source = 'legacy-cpack';`,
start it. Prefer the reconciler (widen `RECONCILE_PO_WINDOW_DAYS` temporarily) for PO
headers.

**Deeper backfill on a fresh tenant.** Delete the cursor row for the source and set
`BACKFILL_SINCE=YYYY-MM-DD`; the next start seeds from there.

**Unsafe**: pointing two instances at the same `CURSOR_SOURCE`; enabling
`KEEP_LEGACY_IDS` for an id-offset tenant; enabling `shadow-mirror` (its source is dead);
any write to the legacy DB.

## Tests

`cd services/analytics-sync && go test ./...` (CI: `.github/workflows/go-services.yml`).
Replicator tests in `internal/replicate/`: `handlers_test.go` (includes
`TestOpenRuntimeWindowOverlapSafeReplay`, `TestStopGuardsAgainstInvertedRange`),
`resolver_test.go`, `reconcile_test.go`, `enrich_test.go`, `config_enrich_test.go`,
`dlq_test.go`. Shadow-mirror tests in `internal/replay/`. Most are SQL-shape and pure-logic
tests; there is no live-DB integration test.

## Source map

| Path | What's there |
|---|---|
| `services/analytics-sync/cmd/legacy-replicator/main.go` | Wiring: pools, resolver, handler registry, reconciler, DLQ retrier, HTTP |
| `services/analytics-sync/internal/replicate/config.go` | Every env var and default |
| `services/analytics-sync/internal/replicate/loop.go` | Poll → dispatch → DLQ → cursor loop |
| `services/analytics-sync/internal/replicate/cursor.go` | `ops.mirror_replay_cursor`, cold-start seeding, `FetchBatch` |
| `services/analytics-sync/internal/replicate/resolver.go` | Base-topic equipment map |
| `services/analytics-sync/internal/replicate/handlers.go` | All SQL and the 14 handlers, overlap matcher, runtime windows |
| `services/analytics-sync/internal/replicate/reconcile.go` | PO reconciler |
| `services/analytics-sync/internal/replicate/enrich.go` | Product/client enrich |
| `services/analytics-sync/internal/replicate/dlq.go` | DLQ table, capture, retrier |
| `services/analytics-sync/internal/metrics/metrics.go` | Prometheus metrics |
| `services/analytics-sync/internal/health/health.go` | Heartbeat `/healthz` |
| `services/analytics-sync/cmd/shadow-mirror/main.go`, `internal/replay/` | Idle in-instance replayer |
| `services/analytics-sync/Dockerfile.replicator`, `Dockerfile` | Images |
| `compose.staging.yml` (`analytics-sync`, `legacy-replicator`, `legacy-replicator-sbx`) | Deployment and staging values |
| `monitoring/prometheus/prometheus.yml`, `monitoring/prometheus/rules.yml` | Scrape jobs, `ReplicatorReplayGaps`, `ShadowMirrorFailures` |
| `docs/adr/0013-shadow-mirror-service.md` | Design decision |
