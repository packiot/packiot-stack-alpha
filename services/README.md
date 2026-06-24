# `services/` — First-party Go services in packiot-stack-alpha

Two Go services live in-repo (not as Git submodules) because they're tightly
coupled to the parent stack's deploy pipeline + don't have independent
release cycles. Both run in `compose.staging.yml` on the AWS staging EC2
and are kept healthy via in-container `--healthcheck` self-probes.

| Service | Role | AMQP/HTTP | DB | Health port |
|---|---|---|---|---|
| [`oeecloud-worker`](./oeecloud-worker/) | Consume PLC data from RabbitMQ, resolve SparkPlug topics → equipment via `packml_register`, write raw data to `equipment_values` + `equipment_events` + `uns_metrics`. **Replaces the decommissioned `oeecloud-node-red` Node-RED service** (retired 2026-06-23). | AMQP consumer on `oee` exchange | TimescaleDB via pgbouncer | 9101 |
| [`mirror-worker-go`](./mirror-worker-go/) | Poll prod `user_logs` via SELECT-only awslambda creds, translate IDs (enterprise → packml_topic → equipment_event → PO via `mirror_id_map`), POST each operator action to staging `edge-api`. **Replaces the TS-implemented `services/mirror-worker`** (retired 2026-06-24 once MW-2 phase 2 reached parity across all 10 eventTypes). Prometheus `/metrics` via `internal/metrics/`; dashboard at `grafana/dashboards/07-mirror-worker.json`. | HTTP to staging edge-api | Prod (SELECT-only) + Staging via pgbouncer | 9102 |

## Shared architectural patterns

Both workers follow the same shape — useful to know if you're touching one
and trying to make the other consistent:

- **Multi-stage Dockerfile**: Go 1.24 Alpine builder → distroless static
  runtime. CGO disabled, `-trimpath` + `-ldflags '-s -w'`, `-p=1` + 
  `GOMAXPROCS=1` to avoid OOM on the 2-CPU staging actions-runner.
- **`cmd/<name>/main.go` entrypoint** + `internal/{config,db,health,log,secrets}/`.
- **Secrets via AWS Secrets Manager** (`internal/secrets/secrets.go`) — both
  read DB creds from `packiot/staging/db` (or `databaseCredentials` for
  prod-side mirror access). oeecloud-worker also pulls AMQP user creds from
  `packiot/staging/rabbitmq-oeecloud-creds` (least-privilege user, configure
  on own topology only, no admin reach).
- **Self-healthcheck via `--healthcheck` subcommand**: distroless images have
  no shell, so the binary itself probes its in-process `/health` server. 
  Used in `healthcheck: { test: ["CMD", "/usr/local/bin/<name>", "--healthcheck"] }`.
- **Graceful shutdown**: both react to SIGTERM by draining in-flight work and
  closing connections cleanly.

## Per-worker docs

- [`oeecloud-worker/docs/strategy-a-worker-pool.md`](./oeecloud-worker/docs/strategy-a-worker-pool.md) — bounded worker-pool design for future scale-up (deferred until ≥100 msg/s sustained or ≥2nd active tenant).
- [`oeecloud-worker/docs/strategy-c-per-tenant-queues.md`](./oeecloud-worker/docs/strategy-c-per-tenant-queues.md) — per-tenant AMQP queue topology (Phase 1 shipped, Phase 2 publisher cutover deferred until edge-node-red Phase 2b debug completes).
- [`oeecloud-worker/docs/onboarding-new-tenant.md`](./oeecloud-worker/docs/onboarding-new-tenant.md) — runbook for adding a new tenant.
- [`mirror-worker-go/docs/architecture.md`](./mirror-worker-go/docs/architecture.md) — cursor-advance loop, ID translation flow (incl. the interval-overlap matcher), dual-cursor history (`cpack-prod` TS vs `cpack-prod-go` Go), the 10 ported eventTypes.

## Observability

- **oeecloud-worker**: exposes Prometheus `/metrics` (collectors in
  `internal/metrics/`); scraped by `monitoring/prometheus/prometheus.yml`
  with `tenant` label; dashboard at `grafana/dashboards/08-oeecloud-worker.json`
  shows acked/nacked/failed counters, throughput, latency p50/p95/p99,
  PO Parameter breakdown, Go runtime stats.
- **mirror-worker-go**: exposes Prometheus `/metrics` (collectors in
  `internal/metrics/`). Five worker-domain metrics —
  `mirror_worker_user_logs_polled_total`,
  `mirror_worker_user_logs_replayed_total{outcome=ok|failed|skipped}`,
  `mirror_worker_replay_duration_seconds`,
  `mirror_worker_cursor_lag_seconds`,
  `mirror_worker_id_map_cache_size` — plus standard `go_*` + `process_*`
  collectors. Scraped at `mirror-worker-go:9102`. Dashboard at
  `grafana/dashboards/07-mirror-worker.json` mixes Prometheus panels
  (cursor lag, replay rate by event_type, outcomes split, p50/p95/p99
  latency, goroutines + RSS) with Postgres panels (DLQ depth, mapping
  growth, recent failed-row drilldown).

## Deploy + bump chain

Both services build from-source via the parent's `compose.staging.yml`
`build:` directives. Pushing changes to either directory follows the
parent's normal staging-gated flow:

1. PR into `packiot-stack-alpha:staging`
2. PR Validation runs (`docker compose config --no-interpolate -q`)
3. Auto-merge after green check
4. `deploy-staging.yml` fires `docker compose up -d --build` on the EC2
   runner — the changed worker's image rebuilds + container recreates.

The auto-bump submodule chain (`bump-stack-submodule.yml`) does NOT apply
to these services because they're first-party, not submodules.

## Closed gaps

- **Local-dev compose parity** — closed by #52 (CREDS_SOURCE=env
  fallback in both `internal/secrets/secrets.go` + dev compose blocks).
  Both workers now boot under `make up` with `make up-workers` available
  as a partial-stack convenience.
- **mirror-worker-go observability parity** — closed by #53. Added
  `internal/metrics/` with five worker-domain Prometheus metrics, wired
  `/metrics` on the health server, registered the new scrape job in
  `monitoring/prometheus/prometheus.yml`, and ported
  `grafana/dashboards/07-mirror-worker.json` queries from the retired TS
  worker's metric names to the new Go metric names.
- **mirror-worker-go test coverage** — closed by #53. Added
  `internal/replay/dispatcher_test.go` (metrics outcome paths),
  `event_justified_test.go` + `order_status_changed_test.go` (payload
  unmarshal edge cases incl. bigint, plus dispatch outcome assertions),
  and `internal/translate/translate_test.go` (pure-function coverage of
  `remapTopic` + `Translator.Enterprise`).
- **mirror-worker-go architectural docs** — closed by #53. See
  [`mirror-worker-go/docs/architecture.md`](./mirror-worker-go/docs/architecture.md).
