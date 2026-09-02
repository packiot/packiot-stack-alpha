# oeecloud-worker

**The Go cloud OEE worker.** A RabbitMQ consumer that reads the SparkPlug B
telemetry stream off the `oee` exchange, decodes it, and writes the raw +
derived rows to TimescaleDB — `equipment_values` (raw counters/state) and
`equipment_events` (derived interval events). It also hosts the scheduled
computations that the legacy stack ran as `pg_cron` PL/pgSQL (runtime rollups,
PO lifecycle math, UNS refreshers, per-customer report writers).

It **replaced the decommissioned `oeecloud-node-red`** cloud engine. During the
migration it was designed to run *alongside* Node-RED: it binds its own queue
(`oeecloud-worker-q`) to the same `oee` topic exchange, so both consumers saw
every published message without competing (`cmd/oeecloud-worker/main.go`). If a
number in the product used to come from a `piot_*` function on prod, its Go
replacement lives here (ADR-0014; name mapping in
`docs/adr/reference/naming-ledger.md`).

## Pipeline position

```
PLC (factory floor)
  │  SparkPlug B (MQTT)
  ▼
edge-node-red / sparkplug-agent   (on-site)
  │  wraps metrics, publishes to the message bus
  ▼
RabbitMQ  ── `oee` topic exchange ──►  oeecloud-worker-q  (routing key '#')
                                              │
                                              ▼
                                     ┌──── oeecloud-worker ────┐
                                     │  decode → resolve topic │
                                     │  → batch-write per msg  │
                                     └────────────┬────────────┘
                                                  │  raw + derived rows
                                                  ▼
                                     TimescaleDB (analytics plane / packiot_analytics)
                                       equipment_values, equipment_events
                                                  │
                                  continuous aggregates (ca_*_1min, ca_discrete_changes_1s)
                                       + this worker's runtime-rollup jobs
                                                  ▼
                                   equipment_runtime_shift / _1hour / _1day / …  →  OEE
```

Reliability topology (`internal/amqp/topology.go`): the worker declares its
queue with a dead-letter path — on a transient failure it `nack`s
(`requeue=false`) to `oee-retry` → `oeecloud-worker-q-retry-30s` (30 s TTL) →
bounces back to `oee` for another attempt, up to `MAX_RETRIES`, after which the
message lands in `oeecloud-worker-q-failed`. Topology is asserted idempotently
on every startup so broker restarts and fresh deploys converge.

## What it does (two halves in one process)

1. **AMQP consumer (always on).** Binds `oeecloud-worker-q` to the `oee`
   exchange, parses each envelope, and batches all of a delivery's per-table
   writes into **one** `pgx.Batch` round-trip. Routing key
   `sparkplug.data[.<tenant>]` is dispatched to the SparkPlug handler
   (`internal/handlers/sparkplug.go`); unknown keys fall through to a
   log-only handler.
2. **Scheduled jobs (flag-gated).** A set of goroutines wired in `main.go`,
   each gated by an env flag and observed via `jobs_ticks_total{job,outcome}`.
   These are the Go ports of the legacy `pg_cron` functions: runtime rollups,
   PO recalc, UNS refresh, per-customer reports, the events deriver, and the
   side-by-side bake comparator. **Almost all default OFF** — enablement per
   environment lives in `compose.staging.yml` / `compose.production.yml`.

> **What computes OEE, precisely.** The worker writes the **raw** stream
> (`equipment_values`) and **derives events** (`equipment_events`). TimescaleDB
> still owns the **continuous aggregates** (`ca_equipment_values_1min`,
> `ca_discrete_changes_1s`) — this worker even ensures the cagg background-worker
> scheduler is running on the shadow DB at boot (`main.go`, `start_background_workers()`).
> The **runtime-rollup cascade** (`equipment_runtime_shift/_1hour/_1day/_1week/_1month`)
> is **no longer DB triggers** — since ADR-0014 it is the Go `rollup` package
> reading the caggs and writing the runtime grains. So "the DB computes OEE" is
> only half true post-port: the DB owns the low-grain caggs; this worker owns
> event derivation and the runtime-grain rollups.

## Code map

| Package | Role |
|---|---|
| `amqp` | RabbitMQ connection, retry/DLX topology, consumer lifecycle |
| `handlers`, `dispatcher` | route routing-key → handler; SparkPlug handler collects writes into one batch |
| `sparkplug` | SparkPlug parse (`parse.go`) + `packml_topic → EquipmentInfo` resolver (`resolver.go`) |
| `writers` | the consume→write path — `equipment_values.go` (counter/state UPSERTs + `BuildEventMint`), `uns_current_metrics.go`, `po_parameter.go`, `increment_clamp.go` |
| `events` | `deriver.go` — the stop-event deriver (gaps-and-islands over the state stream) |
| `rollup` | runtime-grain cascade (hour/day/shift/week/month × equipment/area/site), PO recalc, provisioning, `availability.go` counters-only fallback, `inferspeed.go` |
| `pocontrol` | PackML 30800-series PO lifecycle (start / stop / setup) |
| `shiftresolver` | Go port of the shift-fill trigger (ADR-0014 P2) |
| `uns` | UNS current-state provisioner + week/month refresh matrix |
| `reports` | per-customer writers: speed33, shift06, sap13, sync06, boxes (+ bridge) |
| `refsync` | mirrors master tables main→`packiot_analytics` so analytics rollups read the legacy reference plane |
| `bake` | side-by-side F1↔F3 comparator + int-overflow sentinel (ADR-0016) |
| `flows`, `tenants`, `jobs` | dual-destination fan-out, tenant discovery, the scheduler primitive |
| `config`, `secrets`, `db`, `metrics`, `health`, `tracing`, `log` | plumbing (creds from AWS Secrets Manager, Prometheus, OTLP→Tempo) |

### The consume→write path in detail

- **Topic resolution** (`sparkplug/resolver.go`). Every metric's topic is
  mapped to an `EquipmentInfo` (`id_equipment`, `id_enterprise/site/area`,
  `status_type`, `signal_quality`, `production_speed`) by querying
  `packml_register` joined to `equipments → areas`. Memoised in-process: 5 min
  TTL on hits, 30 s on misses (so a chatty unknown topic can't hammer the DB),
  bounded to defend against a flooding publisher.
- **Raw writes** (`writers/equipment_values.go`). Ports the Node-RED
  "UPSERT: equipment_values" node column-for-column, all keyed on
  `(ts_value, id_equipment)`:
  `ProdProcessedCount → net_production_*`, `ProdConsumedCount → gross_production_*`
  (note: leaf naming is counterintuitive — *Consumed* is the **gross** count),
  `ProdDefectiveCount → scrap_*`, `StateCurrent → state`, `UnitModeCurrent → mode/sub_mode`.
- **Event minting** (`BuildEventMint`, `writers/equipment_values.go` ~L394).
  ADR-0010 §10.4 companion for `KindStateCurrent`: it mints an
  `equipment_events` row from each state sample — **but only for
  `status_type=4` equipment**, because that is the events deriver's scope. The
  gate is load-bearing: for `status_type!=4` equipment (lines/sectors, non-state
  machines) the deriver never cleans up, so a per-sample mint would leave
  open (`ts_end` NULL) events that `running_time` counts to `now()` — a massive
  over-count that once produced 44,182 h/day and an int4 overflow (see the
  EventMint↔deriver scope-mismatch bug). Prod mints those via line-aggregation
  (`forced_creation_system`), not per-sample.

### Event derivation — what derives vs what the DB computes

`events/deriver.go` is the ADR-0014 P3a port of prod's
`piot_review_equipment_events()`. It reconstructs interval events from the
1-second discrete-change cagg (`ca_discrete_changes_1s`) via **gaps-and-islands**
(a `count(state) OVER …` group id + `first_value` per group) instead of the
legacy PL/pgSQL `gapfill(LOCF)` — zero PL/pgSQL in the refactored DB. One job
does both roles the prod split had: the upsert pass *creates and corrects*
transitions; the delete pass removes rows the recomputed stream no longer
supports.

- **Scope: `status_type=4` equipment only** (prod parity). The minter
  (`BuildEventMint`) and the deriver share this scope exactly, so a minted
  OPEN event always has a cleaner in the same scope — never an orphan.
- **CPACK is `status_type=0`.** Its events are pipeline-created (CPAC
  `30758=4`) and reach the shadow flows via the **mirror-worker event fan-out**
  until the ADR-0010 §10.4 port lands. On a CPACK-only staging the deriver is
  idle *by correctness*. **VERIFY** the current enablement state before
  assuming CPACK events flow through this worker.
- **Wide-row exception** (`EVENTS_WIDEROW_STATE_ENTERPRISES`, e.g. Incoplast/ent4):
  tenants that write `state` directly into `equipment_values` and register no
  StateCurrent leaf topics are opted in by enterprise id, restricted to
  `tp_equipment=1` machines (deriving line events from a wide-row would
  double-count — cf. the two-writer line bug).

### Counters-only availability fallback

`rollup/availability.go` handles state-less Modbus machines that emit counts but
no `StateCurrent`, so they'd otherwise show `running_time=0 → oee_a=0`. It
sessionizes running-vs-stopped from **count activity** in the 1-min cagg via
idle-timeout gaps-and-islands: a run of productive minutes whose inter-minute
gap never exceeds the idle timeout is one "session," credited through
`last-count + idle_timeout`. Auto-engages only when the equipment is opted in
(`COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS`) **and** the bucket carried no state
events. Flag-off ⇒ byte-identical to the state-only rollup; it writes a disjoint
row set from the events phase (single-writer discipline, the #456 lesson).

## Build / test / run

```bash
# From services/oeecloud-worker/
go build ./...                 # compile all packages
go test ./...                  # unit tests + golden-fixture + port-fidelity guards

# Golden fixtures (pin legacy business rules — a test failing because you
# "fixed" legacy behavior is working as intended):
go test ./internal/rollup/     # *_golden_test.go: hour/day/shift/silver/counters/inferspeed
go test ./internal/writers/    # bronze_raw_golden_test.go
go test ./internal/pocontrol/  # closefirst_golden_test.go

# Differential harness — run legacy PL/pgSQL vs the Go port on identical
# snapshots in two sandbox schemas, then row-diff (PORTING.md upgrade #1):
go run ./cmd/port-parity -subject hour -emit > parity-hour.sql
```

From the **repo root** via the Makefile:

```bash
make build-oeecloud-worker     # docker compose build oeecloud-worker
make up                        # bring up the local stack (worker runs inside)
make up-workers                # just the two Go workers (oeecloud-worker + mirror-worker-go)
make logs-oeecloud-worker      # tail the AMQP consumer logs
```

The image is a multi-stage distroless build (`Dockerfile`): static CGO-free
binary → `gcr.io/distroless/static-debian12:nonroot`. No shell, so the docker
healthcheck self-probes: the binary re-execs itself as
`oeecloud-worker --healthcheck` and GETs its own `/health` (exit 0 = healthy).
A second one-shot mode, `--identity-sentinel`, is the SELECT-only analytics
int-overflow deploy gate run in CI.

## Config

Credentials come from **AWS Secrets Manager** in staging/prod (EC2 IAM role);
set `CREDS_SOURCE=env` locally to read them straight from compose env vars
(`internal/secrets/secrets.go`). Full list in `internal/config/config.go`.

**Connection / plumbing**

| Env var | Default | Meaning |
|---|---|---|
| `CREDS_SOURCE` | *(unset)* | `env` ⇒ read `DB_*` / `RABBITMQ_*` from env instead of Secrets Manager |
| `AWS_REGION` | `us-east-1` | Secrets Manager region |
| `PG_SECRET_ID` | `packiot/staging/db` | SM id for DB creds (`{DB_HOST,DB_PORT,DB_USER,DB_PASSWORD,DB_NAME}`) |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-oeecloud-creds` | SM id for the least-privilege AMQP user |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / `5672` | broker address |
| `DB_HOST/PORT/USER/PASSWORD/NAME` | `postgres`/`5432`/—/—/`packiot` | direct DB creds (only under `CREDS_SOURCE=env`) |
| `POSTGRES_MAX_CONNS` | `5` | main (F1) pool size |
| `POSTGRES_ANALYTICS_DB_NAME` | *(unset)* | analytics DB name; unset ⇒ `source_type=refactored` routes back to main |
| `POSTGRES_ANALYTICS_MAX_CONNS` | `15` | analytics pool size |
| `LOG_LEVEL` / `HEALTH_PORT` | `info` / `9101` | logging + `/health` + `/metrics` port |

**AMQP topology / consumer**

| Env var | Default | Meaning |
|---|---|---|
| `SOURCE_EXCHANGE` | `oee` | topic exchange the worker binds to |
| `WORKER_QUEUE` | `oeecloud-worker-q` | the durable consume queue |
| `RETRY_EXCHANGE` / `RETRY_QUEUE` | `oee-retry` / `…-q-retry-30s` | dead-letter retry path |
| `FAILED_EXCHANGE` / `FAILED_QUEUE` | `oee-failed` / `…-q-failed` | terminal DLQ after `MAX_RETRIES` |
| `RETRY_TTL_MS` / `MAX_RETRIES` | `30000` / `5` | retry delay + attempt cap |
| `PREFETCH` / `CONSUME_LANES` | `50` / `1` | QoS prefetch + parallel consumer lanes |
| `LEGACY_INGEST_ENABLED` | `true` | `false` ⇒ 10.9 cutover: don't consume per-tenant `sparkplug.data.<tenant>` queues |

**Job toggles** (each ships OFF unless noted; every job is a triplet
`X_ENABLED` / `X_INTERVAL_MINUTES` / ids). Selected examples:

| Env var | Default | Job |
|---|---|---|
| `RUNTIME_ROLLUP_ENABLED` | `false` | runtime-grain cascade (`rollup.LoopGrains`) |
| `EVENTS_DERIVER_ENABLED` | `false` | the events deriver (`events.Loop`) |
| `PO_CONTROL_ENABLED` | `false` | PO lifecycle handler (`pocontrol`) |
| `PO_RECALC_ENABLED` | `false` | `recalc_needed` consumer (`rollup.LoopRefresh`) |
| `UNS_REFRESH_ENABLED` | `false` | UNS provisioner + refreshers |
| `SHIFT_RESOLVER_ENABLED` / `SHIFT_FILL_FOLDED` | `false` / `false` | Go shift-fill (ADR-0014 P2) |
| `COUNTERS_ONLY_AVAILABILITY_ENABLED` | `false` | counters-only availability fallback |
| `INCREMENT_SANITY_CLAMP_ENABLED` | `false` | ADR-0037 Silver increment clamp |
| `BRONZE_RAW_APPEND` | `false` | ADR-0036 medallion Bronze dual-write |
| `BAKE_COMPARATOR_ENABLED` | `false` | F1↔F3 side-by-side bake |
| `REFSYNC_ENABLED` | `true` | reference-plane sync main→shadow |
| `EVENTS_EXCLUDED_AREAS` / `EVENTS_EXCLUDED_ENTERPRISES` | `""` | disabled-customer toggles (config, not algorithm) |

> `source_type` routing: `""` → main pool (F1); `"refactored"` → the shadow
> pool (analytics plane, `packiot_analytics`). The legacy `"go"` / `shadow_go_port` (F2) plane
> was dropped in ADR-0032 Step 5 — only F1 and the analytics plane remain.

## Invariants (read before changing a port)

- **Ports are verbatim-first** (`docs/PORTING.md`). Fidelity-guard and golden
  tests pin legacy business rules *and* amber bugs — a test that fails because
  you "fixed" legacy behavior is working as intended; change the port and the
  guard together, deliberately.
- **One writer per row.** The two-writer line double-count (#456) and the
  EventMint↔deriver scope-mismatch overflow both came from two code paths
  writing the same cell. Minter and cleaner must share scope; disjoint row sets
  per phase.
- **Flag-off = byte-identical.** New behavior ships behind a default-off flag so
  the executed statement stream is unchanged until you opt in per env.
- DB pools use `QueryExecModeSimpleProtocol` (pgbouncer transaction-pooling
  compatibility) — do not remove.

## Contributing

Work on `packiot-stack-alpha` follows a two-branch model:

1. Branch off `development`: `git checkout development && git checkout -b feature/<thing>`
2. PR → `development` (integration scratchpad, not deployed).
3. Promote with a PR `development → staging`. **Auto-deploy fires on `staging`**
   (`deploy-staging.yml` → AWS staging EC2). Parent `staging` is protected —
   direct push is blocked. `main` is reserved for a future production tier; don't push it.

Full workflow, submodule rules, and doc-routing conventions:
[CONTRIBUTING.md](https://github.com/packiot/packiot-stack-alpha/blob/staging/CONTRIBUTING.md).
