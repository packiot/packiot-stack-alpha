---
title: mirror-worker (retired)
layer: 3
owner_area: legacy-bridge
last_verified: 2026-09-28
---
# mirror-worker (retired)

> **Layer 3 · Components** — `services/mirror-worker-go`, the first legacy → staging mirror.
> Retired on 2026-08-13 and replaced by the [legacy-replicator](analytics-sync.md). Read
> this page to understand old data, old metrics and old DLQ rows, or before reviving it.
> Up: [Legacy bridge](../subsystems/legacy-bridge.md)

## Responsibility

Copy CPACK's real production activity from the legacy DB (`packiot40`, enterprise 1) into
staging (enterprise 3) so the new stack could be exercised with real shapes, and measure
how far staging drifted from legacy (a fidelity *comparator*). Unlike the legacy-replicator,
it replayed operator actions **through the staging edge-api over HTTP**, and it also
synthesised counter values and events directly in the database.

!!! warning "Status: retired, not running"
    `compose.staging.yml` keeps the service block but gates it behind the compose profile
    `legacy-comparator`, so a normal deploy does not start it. The Prometheus job is
    commented out (`up{job="mirror-worker-go"}` was confirmed 0 on 2026-08-20). The code is
    still built and tested by CI (`go-services.yml`). `compose.production.yml` does not
    include it.

## At a glance

| | |
|---|---|
| Language / runtime | Go, distroless image (`services/mirror-worker-go/Dockerfile`) |
| Container | `mirror-worker-go` (profile `legacy-comparator`) |
| Host | staging app host (when enabled) |
| Port | `:9102` `/health`, `/metrics` (not published) |
| Source | legacy `packiot40` through Secrets Manager `databaseCredentials` (UPPERCASE keys) |
| Destination | staging edge-api (`STAGING_API_URL`, HTTP) + staging DB (`packiot/staging/db`) + optional `packiot_analytics` fan-out |
| Tenant map | `PROD_ENTERPRISE_ID=1` → `STAGING_ENTERPRISE_ID=3` |
| Limits | 256 MiB, 0.5 CPU |
| Replaced by | [legacy-replicator](analytics-sync.md) (direct SQL, no HTTP hop) |

## Inputs & outputs

| Kind | Object |
|---|---|
| Read (legacy, `BEGIN READ ONLY`) | `user_logs`, `production_orders`, `equipment_events`, `equipment_values`, `packml_register` |
| Write (HTTP) | staging edge-api `POST /api/production-orders/*`, `/api/downtimes/*` with `?token=<ent-3 api_key>&idEnterprise=3` and `Idempotency-Key: cpack-prod-go/<id_user_logs>` |
| Write (SQL) | staging `equipment_values` (counter deltas), `equipment_events` (1:1 mirror), `production_orders` finisher UPDATEs |
| Write (SQL, fan-out) | `packiot_analytics.public` (F3) and formerly `shadow_go_port` (F2) |
| Bookkeeping | `mirror_replay_cursor`, `mirror_id_map`, `mirror_replay_dlq` keyed by `source = cpack-prod-go` |

The edge-api `IdempotencyInterceptor` (24-hour key store in `idempotency_keys`) exists for
this worker's retries.

## Internal design

| Package | Role |
|---|---|
| `cmd/mirror-worker-go` | wiring; starts the replay loop and six background loops |
| `internal/db` | `prod.go` (read-only pool) and `staging.go` (read/write pool, cursor, id map, DLQ) |
| `internal/translate` | prod id → staging id: site/area by name, equipment by `packml_topic` (`C-PACK/` → `CPACK/`), PO via `mirror_id_map` then business key, event via id map then interval-overlap |
| `internal/replay` | one file per category, each builds an edge-api request |
| `internal/reconcile` | PO existence reconciler + finisher, value sync, events sync, close sweep |
| `internal/comparator` | fidelity watchdog (active-PO diff, OEE divergence, event lag, open strands) |

Loops (defaults from `internal/config/config.go`):

| Loop | Interval | What each tick does |
|---|---|---|
| Replay | `POLL_INTERVAL_SEC` 60 s, `BATCH_SIZE` 50, 50 ms between POSTs | Read legacy `user_logs` past the cursor; for each row in one staging tx: skip if already in `mirror_id_map`, else translate + POST, DLQ on failure, advance cursor |
| PO reconciler | 300 s (`RECONCILE_MODE=tail` splits create-diff to 3 s) | Create staging POs that are active in legacy; finisher closes zombies |
| Value sync | 30 s | Insert one synthetic `equipment_values` row per active PO with the (legacy − staging) counter delta; clamps \|delta\| > 1e9 |
| Events sync | 60 s | Mirror legacy `equipment_events` 1:1 (`forced_creation_system=true` to bypass the dedup trigger); optional close sweep |
| DLQ retry / reanimate | 300 s / 600 s | Re-drive DLQ rows with backoff; revive rows whose dependency appeared |
| Comparator | 300 s (OEE every 1800 s) | Publish drift gauges |

Registered categories: `order-status-changed`, `order-created`, `order-created-started`,
`order-started`, `order-changed`, `order-stopped`, `order-replaced`,
`downtime-event-created`. `event-justified`, `event-edited` and `event-splitted` were
deliberately **not** replayed, because the events sync was the sole writer of CPACK
`equipment_events` and a second writer produced primary-key conflicts.

## Configuration

Staging values as last set in `compose.staging.yml` (the service is profile-gated off).

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `PROD_DB_SECRET_ID` | `databaseCredentials` | same | Legacy creds |
| `STAGING_DB_SECRET_ID` | `packiot/staging/db` | same | Staging creds |
| `SOURCE_NAME` | `cpack-prod-go` | same | Cursor / id-map / DLQ key |
| `PROD_ENTERPRISE_ID` / `STAGING_ENTERPRISE_ID` | `1` / `3` | same | Tenant map |
| `POLL_INTERVAL_SEC` / `BATCH_SIZE` / `PER_POST_DELAY_MS` | 60 / 50 / 50 | same | Replay pacing |
| `STAGING_API_URL` | `http://edge-api:8080` | same | Replay target |
| `SHADOW_VALUE_FANOUT` / `SHADOW_FANOUT_F2` | `false` / `true` | `true` / `false` | Fan counter deltas to F3 only |
| `POSTGRES_ANALYTICS_DB_NAME`, `SHADOW_DB_HOST` | empty | `packiot_analytics`, DB host | F3 fan-out target |
| `RECONCILE_ENABLED`, `RECONCILE_MODE` | `true`, `poll` | `true`, `tail` | PO reconciler |
| `RECONCILE_FINISHER_ENABLED`, `_GRACE_MINUTES` | `false`, 30 | `true`, 30 | Close zombie running POs |
| `RECONCILE_CLOSE_PROD_TERMINAL_ORPHANS` | `false` | `true` | Close mirror-created POs whose legacy twin finished |
| `RECONCILE_VALUES_ENABLED`, `RECONCILE_EVENTS_ENABLED` | `true` | `true` | Value / events sync |
| `RECONCILE_EVENTS_CLOSE_SWEEP_ENABLED` | `false` | `true` | Fix late-closed events |
| `DLQ_RETRY_*`, `DLQ_REANIMATE_*`, `COMPARATOR_*` | see config.go | defaults | |
| `EVENT_MIN_OVERLAP_SEC`, `EVENT_MAX_START_DRIFT_SEC` | 30, 600 | defaults | Overlap matcher |

## Data & invariants

- **Legacy is SELECT-only by discipline, not by grant.** The legacy role holds INSERT on
  many tables; every read is wrapped in `BEGIN READ ONLY`. Never remove that wrapper.
- **One staging tx per replayed row**, cursor advances even on failure (DLQ instead).
- **Idempotency via `mirror_id_map`** and the edge-api `Idempotency-Key` store.
- **Sole-writer assumptions**: value sync assumed it was the only writer of CPACK
  `equipment_values` on staging (the simulator skipped enterprise 3); events sync assumed
  the same for `equipment_events`.

## Observability

Metrics are prefixed `mirror_worker_` (for example `mirror_worker_cursor_lag_seconds`,
`mirror_worker_dlq_depth`, `mirror_worker_reconciler_finisher_total{outcome}`,
`mirror_worker_comparator_oee_divergence_pct`). Alerts `MirrorDLQNotEmpty`,
`MirrorCursorLag` and `MirrorOeeDivergence` remain in `monitoring/prometheus/rules.yml` but
have no data while the job is off.

## Failure modes

| Failure | Cause | Lesson |
|---|---|---|
| Noise: ~413 "already mapped" warnings every 3 min | Re-polled rows already in the id map | One of the reasons it was retired |
| Misrouted rows | Non-deterministic `LIMIT 1` over duplicated legacy `packml_register` rows | Order translation reads by `length(packml_topic), id` |
| Counter oscillation (e38 values) | Feedback loop through value sync | Delta clamp, loss-with-alert |
| Staging downtimes missing for CPACK | Value-sync rows carry no state, so the trigger pipeline that derives events never fired | Led to the events sync, then to the replicator inserting base events |

## Operating it

Do not start it unless you need the comparator before a cutover:
`COMPOSE_PROFILES=legacy-comparator docker compose -p stack -f compose.staging.yml up -d mirror-worker-go`.
Starting it next to the legacy-replicator creates **two writers** for CPACK POs and events;
stop the replicator first or accept conflicts. Its cursor (`cpack-prod-go`) and DLQ rows
are preserved in the staging DB.

## Tests

`cd services/mirror-worker-go && go test ./...` (unit tests per package; CI
`go-services.yml`).

## Source map

| Path | What's there |
|---|---|
| `services/mirror-worker-go/cmd/mirror-worker-go/main.go` | Wiring, handler registry, loops |
| `services/mirror-worker-go/internal/config/config.go` | All env vars and defaults |
| `services/mirror-worker-go/internal/translate/translate.go` | Id translation, interval-overlap matcher |
| `services/mirror-worker-go/internal/replay/` | Per-category edge-api replays, DLQ retry/reanimate, HTTP helper |
| `services/mirror-worker-go/internal/reconcile/` | PO reconciler, value sync, events sync |
| `services/mirror-worker-go/internal/comparator/comparator.go` | Fidelity watchdog |
| `services/mirror-worker-go/docs/architecture.md`, `docs/reconciler.md` | Original design notes (partly historical) |
| `compose.staging.yml` (`mirror-worker-go`) | Profile-gated block with the last staging values |
