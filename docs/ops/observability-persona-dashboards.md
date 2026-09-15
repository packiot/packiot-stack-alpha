# Observability — persona-driven Grafana layout

Grafana dashboards are grouped by **who is looking**, not by which component
emits the metric. A Customer Success engineer asking "is my client's data
arriving and is its OEE sane?" should not have to know that the answer lives in
three different component boards. This doc is the canonical map; it supersedes
the drifted pointers in `grafana/README.md` / `grafana/dashboards/_SPEC.md`
(those described a `dashboards-v2/` scheme that no longer exists).

## Two tiers

`foldersFromFilesStructure: true` (in `grafana/provisioning/dashboards/all.yml`)
maps each subdirectory of the mounted dashboards path to a Grafana folder:

```
grafana/dashboards/
  audience/     → Grafana folder "audience"  — start here
    00-overview.json          Firing alerts + stack-alive + does-data-land
    01-cs-client-health.json  ① CS · Client health        (uid aud-cs)
    02-platform-sre.json      ② Platform · SRE            (uid aud-sre)
    03-pipeline-data.json     ③ Pipeline · Data eng       (uid aud-data)
  library/      → Grafana folder "library"   — deep component boards (drill-down)
    03-oee-business, 04-engine, 05-ingest, 07-operator, 08-logs, 09-equipment,
    10-infra, 11-database, 12-api, 13-rabbitmq, 14-uptime-containers,
    15-po-staleness-gate, 16-database-dbm, 17-data-quality, 18-query-traces,
    19-factory-analysis
```

The `library/` boards are unchanged and keep their stable `v2-*` uids, so every
existing `/d/<uid>` link still resolves. The persona boards are a thin,
opinionated layer on top that answers a specific role's first question and links
down into the library for depth.

## The three personas — and why each panel exists

### ① CS · Client health (`aud-cs`)
Audience: Customer Success. Question: *for each client, is data flowing and is
OEE sane?* Isolation is the theme — every client has its **own** RabbitMQ queue,
so "is client X healthy?" is answerable per-queue, not as a blurry global average.

| Signal | Source |
|---|---|
| Ingest rate / errors per client | `oeecloud_worker_batch_writes_total{tenant,result}` (Prometheus) |
| Live data freshness (last-message age) per client | `silver.equipment_values` (SQL, shadow DS) |
| Queue backlog / DLQ / consumer per client | `rabbitmq_detailed_queue_{messages,consumers,consumer_capacity}` |
| OEE + A/P/Q, trend, freshness per client | `gold.equipment_oee_shift` (SQL, shadow DS) |

### ② Platform · SRE (`aud-sre`)
Audience: on-call. Question: *is the platform healthy; if paged, where's the
fire?* Firing alerts → broker → DB → host, in descending blast radius.

Broker health (connections/mem/disk/throughput), **per-queue single-active-consumer
health** (`rabbitmq_detailed_queue_consumers` / `_consumer_capacity` — a queue with
`ready>0` but `capacity==0` is a stalled consumer), DB pool saturation
(`pg_stat_database_numbackends / pg_settings_max_connections` — the real scale
ceiling), longest query / locks / cache-hit, host CPU/mem/disk, container restarts.

### ③ Pipeline · Data eng (`aud-data`)
Audience: data/pipeline engineer. Question: *is the pipeline correct and keeping
up?* Throughput → rollup freshness → durability/DLQ → data-quality invariants.

Worker throughput by client, **scheduled-job ticks by `exported_job`** (see gotcha
below), handler p99, cagg refresh lag scoped to `packiot_analytics`, DLQ/retry
rates, SparkPlug sequence gaps, and `silver.data_quality_event` invariant
violations (OEE_GT_1, NET_GT_GROSS, …).

## Hardproof — the rule that governs this work

**A tile that renders is worthless if its query returns the wrong series or
silently-empty data.** Every panel here was proven against the LIVE staging stack
before being committed — the PromQL run through Prometheus's `/api/v1/query`, the
SQL run against the real datasource DB — and asserted to return a non-empty,
sane-valued result. A `0`/empty is only accepted where it is provably
*healthy-zero* (a CounterVec with no series until the first bad event), and each
such tile says so in its description.

- `scripts/lint-dashboards.py` — **structure** gate (every panel+target pins a
  known datasource uid; no banned/phantom metric names). Recurses
  `grafana/dashboards/**`.
- `scripts/hardproof-dashboards.py` — **behaviour** gate. Runs every Prometheus
  target against a live Prometheus and fails on an empty vector unless the expr is
  in its healthy-empty allowlist. SQL targets use Grafana macros
  (`$__timeFilter`) that only expand in Grafana, so they are listed SKIPPED and
  proven in Grafana or via the SSM DB channel (see
  `scripts/adr0032-f3-fidelity-check.sh`). Run it with a reachable Prometheus:
  `PROM_URL=http://localhost:9090 ./scripts/hardproof-dashboards.py`
  (on the app box / self-hosted runner that's localhost; from a laptop open an
  SSM port-forward to the app instance's :9090 first).

### Live-verification gotchas this work uncovered (keep these — they bite again)
- **`job` label collision.** `oeecloud_worker_job_ticks_total` has its own `job`
  label (runtime-rollup / boxes / *-deriver …), but Prometheus's scrape `job`
  shadows it and renames the original to **`exported_job`**. Break rollup panels
  down by `exported_job`, never `job`.
- **The F1 caggs are a corpse.** `pg_timescaledb_cagg_seconds_since_last_success`
  on `datname="packiot"` shows ~48-day lag by design (ADR-0032). Rollup-freshness
  panels must filter to `datname="packiot_analytics"`.
- **Future-dated shift rows.** `gold.equipment_oee_shift.ts_value` carries
  future rows from shift-calendar projection. Any "latest shift" / trend query
  must guard `r.ts_value <= now()`.
- **Not everything is scraped.** `mirror-worker-go` (scrape commented out) and
  `sparkplug-agent` (no scrape job) emit metrics that have **no live series** —
  panels must not query `mirror_worker_*` / `sparkplug_agent_*`. The old Overview
  had two dead `mirror_worker_*` tiles; they were replaced.

## Prometheus scrape change that this required

Per-queue consumer/SAC monitoring needs metric families the `rabbitmq-detailed`
job did not scrape. Added to `monitoring/prometheus/prometheus.yml`:

```yaml
family: [queue_coarse_metrics, queue_consumer_count, queue_metrics]
```

`queue_consumer_count` → `rabbitmq_detailed_queue_consumers`;
`queue_metrics` → `rabbitmq_detailed_queue_consumer_capacity` (+ per-queue
publish/deliver/ack/redelivered counters). 14 queues → negligible cardinality.

## Related
- `docs/ops/worker-tier-k8s-orchestration.md` — the worker tier + the SLIs these boards surface
- `docs/ops/rabbitmq-topology.md` — canonical per-tenant queue set
- `grafana/dashboards/_SPEC.md` — the library boards' build contract + metric universe
