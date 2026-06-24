# `services/` — First-party Go services in packiot-stack-alpha

Two Go services live in-repo (not as Git submodules) because they're tightly
coupled to the parent stack's deploy pipeline + don't have independent
release cycles. Both run in `compose.staging.yml` on the AWS staging EC2
and are kept healthy via in-container `--healthcheck` self-probes.

| Service | Role | AMQP/HTTP | DB | Health port |
|---|---|---|---|---|
| [`oeecloud-worker`](./oeecloud-worker/) | Consume PLC data from RabbitMQ, resolve SparkPlug topics → equipment via `packml_register`, write raw data to `equipment_values` + `equipment_events` + `uns_metrics`. **Replaces the decommissioned `oeecloud-node-red` Node-RED service** (retired 2026-06-23). | AMQP consumer on `oee` exchange | TimescaleDB via pgbouncer | 9101 |
| [`mirror-worker-go`](./mirror-worker-go/) | Poll prod `user_logs` via SELECT-only awslambda creds, translate IDs (enterprise → packml_topic → equipment_event → PO via `mirror_id_map`), POST each operator action to staging `edge-api`. **Replaces the TS-implemented `services/mirror-worker`** (retired 2026-06-24 once MW-2 phase 2 reached parity across all 10 eventTypes). | HTTP to staging edge-api | Prod (SELECT-only) + Staging via pgbouncer | 9102 |

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

`mirror-worker-go` doesn't yet have a `docs/` directory — see "Open gaps"
below.

## Observability

- **oeecloud-worker**: exposes Prometheus `/metrics` (collectors in
  `internal/metrics/`); scraped by `monitoring/prometheus/prometheus.yml`
  with `tenant` label; dashboard at `grafana/dashboards/08-oeecloud-worker.json`
  shows acked/nacked/failed counters, throughput, latency p50/p95/p99,
  PO Parameter breakdown, Go runtime stats.
- **mirror-worker-go**: **no Prometheus metrics yet** — relies on the
  `mirror_replay_cursor` SQL table for replay-state observability, plus
  `grafana/dashboards/07-mirror-worker.json` (which currently queries the
  TS worker's metrics — needs to be ported once mirror-worker-go exposes
  `/metrics`).

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

## Open gaps (follow-up issues to file)

1. **mirror-worker-go observability parity**: add `internal/metrics/`
   matching oeecloud-worker's pattern (Prometheus counters + histograms),
   wire `/metrics` endpoint, update `prometheus.yml` scrape config, port
   dashboard `07-mirror-worker.json` queries.
2. **mirror-worker-go test coverage**: oeecloud-worker has
   `internal/sparkplug/parse_test.go`. mirror-worker-go has no tests.
   The replay handlers (10 eventTypes in `internal/replay/`) are
   particularly worth testing given they touch ID translation.
3. **mirror-worker-go architectural docs**: oeecloud-worker has 3
   strategy documents. mirror-worker-go has none. Worth at least a
   `docs/architecture.md` explaining the cursor-advance loop, ID
   translation flow, and dual-cursor approach (`cpack-prod` TS-source
   vs `cpack-prod-go` Go-source — though the TS worker is now retired,
   the source label persists for replay-history forensics).

Closed gaps:

- ~~Local-dev compose parity~~ — closed by #52 (CREDS_SOURCE=env
  fallback in both `internal/secrets/secrets.go` + dev compose blocks).
  Both workers now boot under `make up` with `make up-workers` available
  as a partial-stack convenience.
