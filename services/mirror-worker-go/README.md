# mirror-worker-go

Retired legacy-production → staging mirror for CPACK: replays operator actions, syncs PO values and
events, and compares the two sides. Off by default since 2026-08-13.

## What it does

mirror-worker-go copied CPACK activity from the legacy production DB (`packiot40`, legacy enterprise 1)
into staging (analytics enterprise 3) so staging saw real factory shapes. It polls legacy `user_logs`
(the edge-api audit trail), translates legacy ids to staging ids through `mirror_id_map`, and replays
each action as an HTTP POST to the staging edge-api. A reconciler fills the gaps the audit trail misses
(POs started by PLC parameter writes never reach `user_logs`): it creates/starts/finishes POs, syncs PO
counter values and mirrors `equipment_events`. A comparator emits divergence gauges (legacy vs staging).
It was retired on 2026-08-13: the sandbox twin (enterprise 2000003) now supplies staging test data, and it was the
largest log-noise source (comment on the service in `compose.staging.yml`).

## Where it fits

```text
legacy DB packiot40 (SELECT-only, Secrets Manager databaseCredentials)
   │ user_logs, production_orders(_runtime), equipment_events, packml_register
   ▼
mirror-worker-go ──HTTP POST /api/...──▶ edge-api (staging) ──▶ analytics DB
   │
   └── direct writes (pgbouncer / DB host): mirror_id_map, ops.mirror_replay_cursor,
       ops.mirror_replay_dlq, equipment_values / equipment_events (value + events sync)
```

## Status and environments

| Environment | Where | Image | Ports | Health |
|---|---|---|---|---|
| dev (ADR-0060) | not in `dev/compose.yml` | — | — | — |
| staging | `compose.staging.yml` · `mirror-worker-go` · profile `legacy-comparator` (**off**: a normal deploy does not start it) | built from `services/mirror-worker-go/Dockerfile` (Go 1.24 → distroless static) | 9102 (in-network only) | `GET /health`; compose healthcheck runs `mirror-worker-go --healthcheck` |
| production | not in `compose.production.yml` (prod is the source; nothing to mirror) | — | — | — |

The Prometheus scrape job is commented out in `monitoring/prometheus/prometheus.yml` and its Grafana
board was removed (`grafana/dashboards/README.md`, "Retired boards"). Re-enable both together if the
profile is ever turned back on.

## Interfaces

### HTTP

No OpenAPI spec (internal worker, no public API).

| Method | Path | Auth | What |
|---|---|---|---|
| GET | `/health` | none | liveness/readiness of the worker loops |
| GET | `/metrics` | none | Prometheus metrics |

Outbound: POSTs to the staging edge-api at `STAGING_API_URL` (`/api/production-orders/create`,
`/start`, and the handler endpoints for each replayed `user_logs` category).

### Messaging

N/A: no AMQP or MQTT.

### Database

| DB | Access | Objects |
|---|---|---|
| legacy DB (`packiot40`) | SELECT only; every read in a `BEGIN READ ONLY` transaction (`internal/db/prod.go`) | `user_logs`, `production_orders`, `production_orders_runtime`, `equipment_events`, `packml_register`, `areas`, `sites`, `piot_get_*` helpers |
| staging (pgbouncer, secret `packiot/staging/db`) | read/write | `mirror_id_map`, `ops.mirror_replay_cursor`, `ops.mirror_replay_dlq`, `production_orders`, `production_orders_runtime`, `equipment_events`, `core.equipments` |
| analytics DB (`POSTGRES_ANALYTICS_DB_NAME`, host `SHADOW_DB_HOST`) | write when `SHADOW_VALUE_FANOUT=true` | value/event fan-out rows (`gold.production_orders_runtime` read for comparisons) |

## Configuration

Credentials come from AWS Secrets Manager (no passwords in env). With `CREDS_SOURCE=env` they come from
`PROD_DB_*` / `STAGING_DB_*` instead (see the last table).

| Name | Default | Required | Effect |
|---|---|---|---|
| `AWS_REGION` | `us-east-1` | no | Secrets Manager region |
| `PROD_DB_SECRET_ID` | `databaseCredentials` | no | legacy DB credentials secret (SELECT-only role) |
| `STAGING_DB_SECRET_ID` | `packiot/staging/db` | no | staging DB credentials secret |
| `SOURCE_NAME` | `cpack-prod-go` | no | source key on cursor, DLQ and `mirror_id_map` rows |
| `PROD_ENTERPRISE_ID` | `1` | yes (> 0) | legacy enterprise to mirror |
| `STAGING_ENTERPRISE_ID` | `3` | yes (> 0) | staging enterprise to write |
| `POLL_INTERVAL_SEC` | `60` | no | `user_logs` poll cadence |
| `BATCH_SIZE` | `50` | no | `user_logs` rows per poll |
| `PER_POST_DELAY_MS` | `50` | no | pause between edge-api POSTs |
| `STAGING_API_URL` | `http://edge-api:8080` | no | edge-api base URL |
| `SHADOW_VALUE_FANOUT` | `false` | no | also write value deltas to the analytics DB |
| `SHADOW_FANOUT_F2` | `true` | no | include the retired `shadow_go_port` leg of the fan-out |
| `POSTGRES_ANALYTICS_DB_NAME` | empty | no | analytics DB name for the fan-out |
| `SHADOW_DB_HOST` | empty | no | host override for the fan-out pool (pgbouncer does not list the analytics DB) |
| `EVENT_MIN_OVERLAP_SEC` | `30` | no | interval-overlap matcher: minimum overlap to match an event |
| `EVENT_MAX_START_DRIFT_SEC` | `600` | no | matcher: max start drift (stops old open events matching everything) |
| `HEALTH_PORT` | `9102` | no | `/health` + `/metrics` listener |
| `RECONCILE_ENABLED` | `true` | no | active-PO existence reconciler |
| `RECONCILE_INTERVAL_SEC` | `300` | no | combined pass cadence in `poll` mode |
| `RECONCILE_MAX_PER_RUN` | `20` | no | POs created per pass |
| `RECONCILE_MODE` | `poll` | no | `poll` = one combined pass; `tail` = create-diff and finisher on separate tickers (anything else → `poll`) |
| `RECONCILE_CREATE_INTERVAL_SEC` | `3` | no | `tail` mode create-diff cadence |
| `RECONCILE_FINISHER_INTERVAL_SEC` | `300` | no | `tail` mode finisher cadence |
| `RECONCILE_FINISHER_ENABLED` | `false` | no | close staging POs whose legacy twin is no longer running |
| `RECONCILE_FINISHER_GRACE_MINUTES` | `30` | no | skip POs active in legacy within this window |
| `RECONCILE_CLOSE_PROD_TERMINAL_ORPHANS` | `false` | no | also close mirror-created status 1/2 POs whose legacy twin is finished |
| `RECONCILE_VALUES_ENABLED` | `true` | no | PO counter value sync |
| `RECONCILE_VALUES_INTERVAL_SEC` | `30` | no | value sync cadence |
| `RECONCILE_EVENTS_ENABLED` | `true` | no | `equipment_events` mirror |
| `RECONCILE_EVENTS_INTERVAL_SEC` | `60` | no | events sync cadence |
| `RECONCILE_EVENTS_BATCH_SIZE` | `200` | no | events per tick |
| `RECONCILE_EVENTS_CLOSE_SWEEP_ENABLED` | `false` | no | re-close shadow events left open |
| `RECONCILE_EVENTS_CLOSE_SWEEP_EVERY_N_TICKS` | `10` | no | sweep cadence in events ticks (min 1) |
| `RECONCILE_EVENTS_CLOSE_SWEEP_RECENT_HOURS` | `72` | no | sweep lookback |
| `RECONCILE_EVENTS_CLOSE_SWEEP_TIMEOUT_SEC` | `30` | no | sweep watchdog |
| `RECONCILE_EVENTS_CLOSE_SWEEP_BATCH_SIZE` | `500` | no | sweep page size |
| `DLQ_RETRY_ENABLED` | `true` | no | retry `ops.mirror_replay_dlq` rows with backoff (1, 2, 4, 8, 16 min) |
| `DLQ_RETRY_INTERVAL_SEC` | `300` | no | retry loop cadence |
| `DLQ_RETRY_MAX_ATTEMPTS` | `5` | no | attempts before a row stays for triage |
| `DLQ_RETRY_BATCH_SIZE` | `50` | no | rows per retry pass |
| `DLQ_REANIMATE_ENABLED` | `true` | no | re-arm exhausted rows that became mappable |
| `DLQ_REANIMATE_INTERVAL_SEC` | `600` | no | reanimator cadence |
| `DLQ_REANIMATE_BATCH_SIZE` | `100` | no | rows per reanimator pass |
| `COMPARATOR_ENABLED` | `true` | no | legacy-vs-staging comparator (SELECT-only both sides) |
| `COMPARATOR_INTERVAL_SEC` | `300` | no | comparator cadence |
| `COMPARATOR_OEE_INTERVAL_SEC` | `1800` | no | OEE divergence cadence |
| `COMPARATOR_EVENT_OPEN_STRAND_HOURS` | `48` | no | age at which an open event counts as stranded |
| `LOG_LEVEL` | `info` | no | slog level |
| `CREDS_SOURCE` | unset | no | `env` = read DB creds from env instead of Secrets Manager |
| `PROD_DB_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_NAME` | `postgres` / `5432` / — / — / `packiot` | USER+PASSWORD when `CREDS_SOURCE=env` | legacy-side creds (env mode) |
| `STAGING_DB_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_NAME` | same | same | staging-side creds (env mode); prefix chosen by whether the secret id contains `staging` |

The staging block sets `RECONCILE_MODE=tail`, the finisher, the terminal-orphan closer and the close
sweep on, and `SHADOW_VALUE_FANOUT=true` with `SHADOW_FANOUT_F2=false`.

## Run locally

There is no dev slice (it needs the legacy DB). Unit tests only:

```sh
cd services/mirror-worker-go && go test ./...
```

CI runs `go vet`, `go test -race` and `go build` in `.github/workflows/go-services.yml`.

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`) rebuilds
  it, but it only runs when `COMPOSE_PROFILES` in `/opt/packiot/.env` includes `legacy-comparator`.
- **Metrics** (`internal/metrics/`): `mirror_worker_user_logs_polled_total`,
  `mirror_worker_user_logs_replayed_total{outcome}` (`ok|failed|skipped|terminal`),
  `mirror_worker_replay_duration_seconds`, `mirror_worker_cursor_lag_seconds`,
  `mirror_worker_id_map_cache_size`, `mirror_worker_dlq_depth`, `mirror_worker_dlq_retry_attempts_total`,
  `mirror_worker_dlq_reanimated_total`, `mirror_worker_reconciler_*` (runs, pos, values synced,
  events, finisher, orphan candidates, prod-terminal closer, active drift, shadow fan-out),
  `mirror_worker_value_fanout_total`, `mirror_worker_comparator_*` (active PO diff, events lag,
  OEE divergence, DLQ anomaly, user_logs lag, open strands). No dashboard and no scrape job today.
- **Invariants with history:**
  - The legacy role is not structurally write-proof; `BEGIN READ ONLY` on every legacy read is the guard.
  - Value sync drops a per-tick delta above `1e9` (`deltaSanityCap`, `internal/reconcile/value_sync.go`)
    with a log, instead of writing it.
  - Translation queries order by `length(packml_topic), id` so duplicated legacy rows resolve
    deterministically (`internal/translate/translate.go`).
  - Events match by interval overlap, not equality: the two systems trigger events independently.
- **Failure modes:** rows that cannot be translated go to `ops.mirror_replay_dlq` (check depth and
  `last_error`); a host-port clash during `up -d` once left the container in `created` (caught by the
  deploy's service-state gate).

## Code layout

| Path | What |
|---|---|
| `cmd/mirror-worker-go/main.go` | boot, secrets, pools, loop wiring, `--healthcheck` |
| `internal/config/` | env parsing and guards |
| `internal/secrets/` | Secrets Manager / `CREDS_SOURCE=env` credentials |
| `internal/db/` | `prod.go` (read-only legacy reads), `staging.go` (cursor, DLQ, mappings) |
| `internal/translate/` | legacy → staging id translation, interval-overlap event matcher |
| `internal/replay/` | dispatcher + one handler per `user_logs` category, DLQ retry and reanimator |
| `internal/reconcile/` | existence reconciler, finisher, value sync, events sync, close sweep |
| `internal/comparator/` | ADR-0008 fidelity watchdog gauges |
| `internal/health/`, `internal/metrics/`, `internal/log/` | `/health` + `/metrics`, collectors, slog |

## Related docs

- [docs/architecture.md](docs/architecture.md) — cursor loop, id translation, handlers
- [docs/reconciler.md](docs/reconciler.md) — reconciler passes runbook
- [ADR-0008 comparator split](../../docs/adr/0008-phase-2-comparator-split.md)
- [ADR-0024 phased mirror retirement](../../docs/adr/0024-phased-mirror-retirement.md)
- [ADR-0025 three-flow PO state reconciliation](../../docs/adr/0025-three-flow-po-state-reconciliation.md)
- [Sandbox twin runbook](../../docs/runbooks/sandbox-twin.md) — what replaced the mirror as staging test data

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [mirror-worker](https://wiki.packiot.app/understand/components/mirror-worker/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
