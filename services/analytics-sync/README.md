# analytics-sync

Replays operator actions (`user_logs`) into the analytics DB: one Go module, two binaries —
`analytics-sync` (idle on staging) and `legacy-replicator` (the CPACK twin feed, live on staging).

## What it does

Operator actions (start/stop a production order, justify or split a downtime, add a manual event)
are written by edge-api and logged in `user_logs`. Telemetry alone does not carry them, so this
module polls `user_logs` on a cursor, dispatches each row by `category` to a handler, and re-applies
the effect idempotently by natural key (`(id_enterprise, id_order)` for POs,
`(id_equipment, ts_event)` for events). The cursor advances on every row, so the loop never wedges.

- **`analytics-sync`** (`cmd/shadow-mirror`, formerly shadow-mirror, ADR-0013) replayed actions
  *within* one instance, from the F1 `packiot` DB into `packiot_analytics`. Its source DB is retired;
  it runs **idle** on staging (`SHADOW_MIRROR_ENABLED=false`) and only serves `/healthz` + `/metrics`.
- **`legacy-replicator`** (`cmd/legacy-replicator`) replays *across* instances: CPACK actions from the
  **legacy DB** (`packiot40`, enterprise 1, SELECT-only) into the **analytics DB** (enterprise 3, and
  the sandbox twin 2000003 via `legacy-replicator-sbx`). It maps ids at the boundary
  (`internal/replicate/resolver.go`: enterprise by config, equipment by PackML base topic, PO by
  `id_order`) and runs reconcilers that copy what never passes through `user_logs` (POs, product/client
  ids, manual events, PLC base events).

## Where it fits

```text
 legacy DB packiot40 (ent 1)                         analytics DB packiot_analytics
 ┌───────────────────────────┐   SELECT only        ┌──────────────────────────────────────┐
 │ user_logs                 │ ───────────────────▶ │ legacy-replicator      → ent 3       │
 │ production_orders         │                      │ legacy-replicator-sbx  → ent 2000003 │
 │ equipment_events(_man)    │                      │   writes core.production_orders,     │
 │ packml_register           │                      │   gold.production_orders_runtime,    │
 └───────────────────────────┘                      │   silver.equipment_events(_man),     │
                                                    │   ops.mirror_replay_cursor/_dlq      │
 F1 packiot DB (retired) ─ ─ ─ ▶ analytics-sync     └──────────────────┬───────────────────┘
                                 (idle)                                 ▼
                                                    stream-engine rollups, read-api, front4
```

## Status and environments

| Environment | Where (compose file · service · profile) | Image | Ports | Health |
|---|---|---|---|---|
| dev | `dev/services/analytics-sync.yml` · `analytics-sync` · slice `ingest` | built from `Dockerfile` | in-network 9103 | `--healthcheck` → `/healthz` |
| staging | `compose.staging.yml` · `analytics-sync` · no profile, **idle** | built from `Dockerfile` | in-network 9103 | `--healthcheck` |
| staging | `compose.staging.yml` · `legacy-replicator` (ent 1 → 3) · no profile | built from `Dockerfile.replicator` | in-network 9104 | `--healthcheck`; `/healthz` 503 after 600 s without a successful poll |
| staging | `compose.staging.yml` · `legacy-replicator-sbx` (ent 1 → 2000003) · no profile | built from `Dockerfile.replicator` | in-network 9114 | same; enabled only when `.env` sets `REPLICATE_SBX_ENABLED=true` |
| production | not in `compose.production.yml` (no legacy source in a greenfield prod) | — | — | — |

Both images: Go 1.25 Alpine builder → `gcr.io/distroless/static-debian12:nonroot`. Neither binary
publishes a host port.

## Interfaces

### HTTP

| Method | Path | Auth | What |
|---|---|---|---|
| GET | `/healthz` | none (in-network) | 200 while up; the replicator returns 503 when `HEALTHCHECK_MAX_AGE_SEC` > 0 and the loop is stale |
| GET | `/metrics` | none (in-network) | Prometheus metrics |

No OpenAPI spec: there is no business API.

### Messaging

N/A: neither binary uses RabbitMQ or MQTT; both poll Postgres.

### Database

| Binary | Reads | Writes |
|---|---|---|
| analytics-sync (when enabled) | `packiot.public.user_logs` | `shadow_go_port.*` (main pool) and `packiot_analytics.public.*`; cursor `mirror_replay_cursor` source `shadow-mirror` |
| legacy-replicator | legacy `user_logs`, `production_orders`, `equipment_events`, `equipment_events_man`, `packml_register`, products/clients | analytics `core.production_orders`, `core.products`/`clients`/`product_families`, `gold.production_orders_runtime`, `silver.equipment_events`, `silver.equipment_events_man`, `ops.mirror_replay_cursor` (source = `CURSOR_SOURCE`), `ops.mirror_replay_dlq`, `ops.legacy_manual_event_link`; calls `serving.refresh_downtime_events_resolved`; reads `ops.sandbox_held()` |

## Configuration

### analytics-sync (`internal/config/config.go`, `cmd/shadow-mirror/main.go`)

| Name | Default | Required | Effect |
|---|---|---|---|
| `SHADOW_MIRROR_ENABLED` | `false` | no | `true` runs the replay loop; otherwise idle (health + metrics only). Staging and dev: `false` |
| `DB_HOST` / `DB_PORT` / `DB_USER` | `postgres` / `5432` / `postgres` | when enabled | DB server (staging: the DB EC2 directly) |
| `DB_PASSWORD` | — | when enabled | Refuses to boot if empty. Staging: `POSTGRES_PASSWORD` from `.env` |
| `PG_DB_NAME` | `packiot` | no | Source DB (`user_logs`, `shadow_go_port`) |
| `PG_ANALYTICS_DB_NAME` | `packiot_analytics` | no | Second sink; empty = write `shadow_go_port` only |
| `POLL_INTERVAL_MS` / `BATCH_SIZE` | `2000` / `100` | no | Loop pacing |
| `HEALTH_PORT` | `9103` | no | HTTP listener; also read by `--healthcheck` |
| `LOG_LEVEL` | `info` | no | slog level |
| `AWS_REGION`, `PG_SECRET_ID`, `MAX_RETRIES` | `us-east-1`, `packiot/staging/db`, `5` | no | Loaded but **unused** (Secrets Manager fetch is a TODO; credentials come from env) |

### legacy-replicator (`internal/replicate/config.go`)

| Name | Default | Required | Effect |
|---|---|---|---|
| `REPLICATE_ENABLED` | `false` | no | Master toggle; off = idle. Staging: `true` (sbx: `REPLICATE_SBX_ENABLED`, default `false`) |
| `LEGACY_DB_HOST` / `_PORT` / `_USER` / `_NAME` | legacy prod host / `5432` / `awslambda` / `packiot40` | no | Source (SELECT-only user) |
| `LEGACY_DB_PASSWORD` | — | yes when enabled | `.env` `LEGACY_DB_PASSWORD` |
| `DEST_DB_HOST` / `_PORT` / `_USER` / `_NAME` | staging DB EC2 / `5432` / `postgres` / `packiot_analytics` | no | Destination (all writes + cursor) |
| `DEST_DB_PASSWORD` | — | yes when enabled | `.env` `POSTGRES_PASSWORD` |
| `SRC_ENTERPRISE` / `DST_ENTERPRISE` | `1` / `3` | no | Enterprise map (sbx: `DST_ENTERPRISE=2000003`) |
| `BACKFILL_SINCE_DAYS` / `BACKFILL_SINCE` | `60` / — | no | Cold-start history depth; `BACKFILL_SINCE` (RFC 3339 or `YYYY-MM-DD`) wins. An existing cursor is always kept |
| `CURSOR_SOURCE` | `legacy-cpack` | no | `ops.mirror_replay_cursor.source` key (sbx: `legacy-sbxcpack`) |
| `REPLICATE_BASE_EVENTS` | `true` | no | Replay `downtime-event-created` into `silver.equipment_events` |
| `POLL_INTERVAL_MS` / `BATCH_SIZE` | `3000` / `200` | no | Loop pacing |
| `HEALTH_PORT` | `9104` | no | HTTP listener (sbx: `9114`) |
| `HEALTHCHECK_MAX_AGE_SEC` | `0` (off) | no | `/healthz` 503 when no successful poll within N s. Staging: `600` |
| `LOG_LEVEL` | `info` | no | slog level |
| `SANDBOX_HOLD_ENABLED` | `false` | no | Every writer stands down while `ops.sandbox_held(DST_ENTERPRISE)` (sbx: `true`) |
| `RECONCILE_PO_ENABLED` / `_INTERVAL_SEC` / `_WINDOW_DAYS` | `false` / `300` / `14` | no | PO reconciler (`reconcile.go`, `reconcile_converge.go`). Staging: on |
| `RECONCILE_PO_ENRICH_ENABLED` / `_WINDOW_DAYS` | `false` / `14` | no | Copy `id_product`/`id_client` into twin POs (`enrich.go`). Staging: on, 120 days |
| `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` | `true` | no | Create missing dimensions with legacy ids; must be `false` for the +2M sandbox |
| `RECONCILE_MANUAL_EVENTS_ENABLED` | `false` | no | Manual-event reconciler (`manual_reconcile.go`); when on, the manual-event replay handlers are not registered. Staging: on |
| `RECONCILE_MANUAL_EVENTS_INTERVAL_SEC` / `_LOOKBACK_DAYS` / `_MAX_DELETES` / `_REFRESH_SERVING` | `300` / `35` / `50` / `true` | no | Its pacing, window, delete guard and serving refresh |
| `RECONCILE_BASE_EVENTS_ENABLED` | `false` | no | Base (PLC) event reconciler (`base_reconcile.go`); also needs `REPLICATE_BASE_EVENTS`. Staging: on |
| `RECONCILE_BASE_EVENTS_INTERVAL_SEC` / `_LOOKBACK_HOURS` / `_REFRESH_SERVING` | `120` / `72` / `true` | no | Its pacing and window (staging: 96 h) |
| `EVENT_MIN_OVERLAP_SEC` / `EVENT_MAX_START_DRIFT_SEC` | `30` / `600` | no | Interval-overlap fallback matcher for justify/edit/split |
| `DLQ_CAPTURE_ENABLED` / `DLQ_RETRY_ENABLED` | `true` / `true` | no | Capture failed dispatches into `ops.mirror_replay_dlq`; retry them |
| `DLQ_RETRY_INTERVAL_SEC` / `_MAX_ATTEMPTS` / `_BATCH_SIZE` | `120` / `5` / `100` | no | DLQ retrier pacing |

Golden tests also read `DATABASE_URL` (test-only).

## Run locally

```sh
make dev SVC="analytics-sync"        # boots idle, like staging (SHADOW_MIRROR_ENABLED=false)
make dev-smoke SVC="analytics-sync"
```

`legacy-replicator` has no dev slice: it reads the legacy production DB, which has no stand-in
(`dev/README.md`, "Not in dev").

```sh
cd services/analytics-sync
go test ./...                                                     # unit tests (CI: go-services.yml)
DATABASE_URL=postgres://... go test -tags golden ./internal/replicate/   # DB-backed golden tests
```

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`)
  rebuilds both images from source.
- **Metrics** (`internal/metrics/metrics.go`; scraped as jobs `analytics-sync` :9103 and
  `legacy-replicator` :9104 in `monitoring/prometheus/prometheus.yml`):
  `shadow_mirror_dispatched_total`, `shadow_mirror_skipped_total`, `shadow_mirror_failed_total`,
  `shadow_mirror_update_noop_total` (a zero-row UPDATE = a replay gap), `shadow_mirror_cursor`,
  `legacy_replicator_reconcile_{inserted,finished,unresolved,enriched}_total`,
  `legacy_replicator_reconcile_enrich_skipped_total`, `legacy_replicator_manual_events_total{action}`,
  `legacy_replicator_base_events_total`, `legacy_replicator_dlq_retried_total`,
  `legacy_replicator_dlq_depth`. The `shadow_mirror_` prefix is kept for both binaries.
- **Alerts** (`monitoring/prometheus/rules.yml`): `ShadowMirrorFailures`
  (`increase(shadow_mirror_failed_total[15m]) > 0`) and `ReplicatorReplayGaps`
  (update no-ops on job `legacy-replicator` for 30 min).
- **Dashboards:** none of the JSON dashboards under `grafana/dashboards/` queries these metrics.
- **Failure modes:**
  - *Wedged loop* — `/healthz` 503 after `HEALTHCHECK_MAX_AGE_SEC`, Docker marks the container unhealthy.
  - *Silent no-op* — a legacy row resolves to no twin row (`shadow_mirror_update_noop_total`); usually
    an equipment without a matching PackML base topic in the twin.
  - *Missing table* (42P01) is fail-open in the replay handlers of both binaries: a dropped table
    loses writes silently. This is how manual events after 2026-09-12 were lost (the `public.`
    shim was dropped) until the manual reconciler took over.
  - *Sandbox held* — `legacy-replicator-sbx` writes nothing while `ops.sandbox_held(2000003)`
    ([`docs/runbooks/sandbox-twin.md`](../../docs/runbooks/sandbox-twin.md)).
- **One-off repair:** `scripts/backfill-event-fcs-from-legacy.sh` (applied 2026-09-25; `MODE=dry` default).

## Code layout

| Path | What |
|---|---|
| `cmd/shadow-mirror/` | `analytics-sync` entrypoint (idle mode, handler registration, HTTP) |
| `cmd/legacy-replicator/` | `legacy-replicator` entrypoint (pools, handlers, reconcilers, DLQ retrier) |
| `internal/config/` | analytics-sync env config |
| `internal/replay/` | cursor, dispatcher, loop; `handlers/` per `user_logs` category |
| `internal/replicate/` | legacy-replicator: config, resolver (id map), handlers, loop, cursor, `dlq.go`, `reconcile*.go` (POs), `enrich.go`, `manual_reconcile.go`, `base_reconcile.go`, `hold.go`, `flexnum.go` |
| `internal/db/`, `internal/health/`, `internal/log/`, `internal/metrics/` | pgx pools, liveness, slog, Prometheus registry |
| `Dockerfile`, `Dockerfile.replicator` | one image per binary |
| `scripts/` | one-off legacy backfill |

## Related docs

- [ADR-0013 — shadow-mirror service](../../docs/adr/0013-shadow-mirror-service.md)
- [ADR-0012 — schema refactor and multi-tenancy pool](../../docs/adr/0012-schema-refactor-and-multitenancy-pool.md)
- [ADR-0060 — local development environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)
- [ADR-0062 — production-order identity](../../docs/adr/0062-production-order-identity-and-alphanumeric-numbers.md)
- [Runbook: sandbox twin](../../docs/runbooks/sandbox-twin.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [analytics-sync](https://wiki.packiot.app/understand/components/analytics-sync/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
