---
title: stream-engine
layer: 3
owner_area: compute
last_verified: 2026-09-28
---
# stream-engine

> **Layer 3 · Component** — the Go worker that writes ingested Sparkplug envelopes into Bronze and
> Silver and runs every scheduled OEE job (rollups, events, production orders, UNS live tables,
> customer reports). For engineers changing OEE math, adding a tenant, or debugging stale numbers.
> Up: [Compute subsystem](../subsystems/compute.md) · Also part of the
> [ingestion subsystem](../subsystems/ingestion.md) (its AMQP consumer)

## Responsibility

stream-engine is accountable for **turning raw counter/state samples into the OEE numbers the
product serves**. It has two halves in one process:

1. **Ingest consumer**: reads envelopes from RabbitMQ, resolves each Sparkplug topic to an
   equipment through `packml_register`, and writes `bronze.equipment_values_raw` (append-only) and
   `silver.equipment_values` (one row per equipment-second), plus a few side tables.
2. **Scheduled jobs**: about 15 ticker loops that compute `gold.equipment_oee_*` grains from
   Silver, continuous aggregates and `silver.equipment_events`, derive and close events, compute
   production-order runtime, refresh the UNS live tables and write customer report pools.

The code started as a port of the legacy Node-RED `oeecloud` flow and the PL/pgSQL OEE engine
(ADR-0014), which is why many comments say "prod-verbatim" or "parity". The binary is
`stream-engine`; its main package, metric names (`oeecloud_worker_*`) and network alias
(`oeecloud-worker`) keep the old name.

## At a glance

| | |
|---|---|
| Language / runtime | Go 1.25, distroless, `pgx/v5`, `amqp091-go` |
| Repo path | `services/stream-engine` (main: `cmd/oeecloud-worker/main.go`) |
| Compose service | `stream-engine` (`compose.staging.yml`), container `stream-engine`, IP `172.18.0.20`, alias `oeecloud-worker` |
| Image | built from `services/stream-engine/Dockerfile`, entrypoint `/usr/local/bin/stream-engine` |
| Host (staging) | staging app host; DB connections go **directly** to the DB EC2, not through `pgbouncer` |
| Ports | 9101 `/health`, `/metrics` (in-network only) |
| Limits | `mem_limit: 256m`, `cpus: 0.5`, replicas `${OEECLOUD_WORKER_REPLICAS:-1}` |
| Pools | main pool (`POSTGRES_MAX_CONNS`, 5) + analytics pool (`POSTGRES_ANALYTICS_MAX_CONNS`, 15); both open `packiot_analytics` on staging |
| Depends on | RabbitMQ, analytics DB (TimescaleDB), `db-migrate` completed |
| Depended on by | everything that reads Silver/Gold: read-api `serving.*`, Superset, historian live tier |
| Subcommands | `--healthcheck` (Docker probe), `--identity-sentinel` (deploy gate: no `running_time` above 1.05 × bucket span) |

## Inputs & outputs

### Ingest path (per AMQP message)

| Reads | Writes (staging schemas) |
|---|---|
| Queues `stream-engine-q-<tenant>` (and `stream-engine-q`) on exchange `oee` | `silver.equipment_values` — UPSERT on `(ts_value, id_equipment)` |
| `packml_register` ⨝ `areas` ⨝ `equipments` (resolver, cached) | `bronze.equipment_values_raw` — append (`BRONZE_RAW_APPEND`) |
| `sites`, `equipments`, `shift_hours` (shift resolver, cached) | `silver.equipment_events` — per-sample mint for `status_type = 4` state metrics |
| | `bronze.equipment_events_raw` — append of those mints |
| | `silver.equipment_live_metrics` — `CurMachSpeed` metrics |
| | `silver.equipment_values` — parameter 30701 (ideal speed) and 30850 (analogs) |
| | PO lifecycle tables (`core.production_orders`, `gold.production_orders_runtime`, `silver.equipment_live_job`, `identity.user_logs`, …) — parameters 30700, 30800–30803, 30805, 30810–30814, 30820, 30861, 30862, 30880 when `PO_CONTROL_ENABLED` |
| | `silver.data_quality_event` — `INVARIANT_CLAMPED_INCREMENT`, best-effort |

The destination is chosen by the envelope's `source_type`: `refactored` → the analytics pool with
schemas `silver` / `bronze` / `gold` / `core` / `identity`; empty → the main pool, schema `public`
(the single-flow production shape). `source_type = "go"` envelopes are acked and dropped (retired
F2 leg).

### Background jobs

Read Silver facts, the continuous aggregates `silver.equipment_categorical_1min`,
`silver.equipment_categorical_1hour`, `silver.ca_discrete_changes_1s`, `silver.equipment_events`,
`core.*` reference tables and `config.production_targets`. Write `gold.equipment_oee_{hourly,daily,
weekly,monthly,shift}`, `gold.area_oee_{daily,shift}`, `gold.site_oee_shift`,
`gold.production_orders_runtime`, `core.production_orders` OEE columns,
`silver.equipment_events` (derivers, closer), `silver.equipment_live_*` / `silver.area_live_*`,
`silver.data_quality_event`, `customer_reports.*`, and `core.equipments.production_speed`
(inference only). The schema layout is described in
[analytics DB schemas](analytics-db-schemas.md).

## Internal design

### Packages

| Package | Role |
|---|---|
| `internal/amqp` | topology, consumer, lanes, retry/failed routing, tenant discovery loop |
| `internal/handlers` | dispatcher, `SparkplugHandler` (one `pgx.Batch` per delivery) |
| `internal/writers` | SQL builders: `equipment_values`, `increment_clamp`, `uns_current_metrics`, `po_parameter` |
| `internal/sparkplug` | envelope parse, metric classification, topic resolver |
| `internal/shiftresolver` | Go port of the shift trigger (`id_shift`, `id_shift_hour`, `ts_value_production`) |
| `internal/pocontrol` | PO lifecycle state machine (ADR-0010 10.3) |
| `internal/rollup` | OEE grains, backfill, provision, PO compute/recalc, DQ, clamps, inference |
| `internal/events` | status-4 deriver, CPAC count-silence deriver, stale-open closer |
| `internal/uns` | UNS live tables |
| `internal/reports` | customer report writers (enterprises 6 and 13, boxes) |
| `internal/jobs` | the ticker loop used by every job (timeouts, panic recovery, tick metric) |
| `internal/flows` | destination list (one dest: `packiot_analytics`, or `public` when no analytics pool) |
| `internal/oeeprofile` | boot-time load of line-lead enterprises from `client_descriptors` |
| `internal/bake` | the `--identity-sentinel` check |

### The ingest consumer

1. **Topology** (`internal/amqp/topology.go`): declares `oee`, `oee-retry`, `oee-failed`, the shared
   queue triple, and one triple per tenant. Details in [brokers](brokers.md).
2. **Tenant discovery**: `SELECT DISTINCT lower(split_part(packml_topic,'/',1)) FROM packml_register
   WHERE active`, intersected with `WORKER_TENANT_ALLOWLIST`, at boot and every
   `TENANT_DISCOVERY_INTERVAL_SECONDS`. A new tenant starts consuming without a restart. **This
   only runs when `LEGACY_INGEST_ENABLED=true`** (the name is historical). With it false, no
   per-tenant queue is consumed, which on staging (per-tenant routing) would stop all ingest.
3. **Lanes**: each queue has `CONSUME_LANES` goroutines; a delivery goes to lane
   `hash(source_type) % N`. Since staging now emits only `refactored`, all messages of a queue land
   in one lane and each tenant queue is processed serially.
4. **Handler** (`internal/handlers/sparkplug.go`):
   - Parse the envelope. A JSON string of JSON is dropped (poison guard). Other parse failures are
     retried only if legacy ingest is on.
   - Fill missing or implausible metric timestamps (< 2015-01-01) from the payload timestamp,
     then from now.
   - For each metric, classify by name and build one or more statements into one `pgx.Batch`.
     Unregistered topics are skipped and counted in `packml_unresolved_topic_total{tenant}`.
   - Send the batch in one round-trip. Any statement error → nack → retry loop (writes are
     upserts, so a retry is safe for Silver).
   - Side-write clamp events to `data_quality_event` after the batch, errors swallowed.
5. **Resolver** (`internal/sparkplug/resolver.go`): topic → `(id_enterprise, id_site, id_area,
   id_equipment, signal_quality, day_begin, status_type, production_speed)`. The lookup key is the
   first five topic segments, or four when segment 4 is `Admin`/`Status`/`Command` (a line). Cache
   5 min for hits, 30 s for misses, max 10 000 entries.

**Silver UPSERT semantics** (`internal/writers/equipment_values.go`): `ts_value` is truncated to
the second. Each counter kind writes its own columns (`net_production_incr/_val` for processed,
`gross_production_incr/_val` for consumed, `scrap_incr/_val` for defective, `state`, `mode`).
On conflict the increment is **replaced**, not summed. Two samples of the same counter within one
second keep only the last increment in Silver; Bronze keeps both. `tp_equipment` is 3 for line
topics and 1 otherwise. With `SHIFT_FILL_FOLDED=true` the shift columns ride inside the upsert
(`COALESCE` keeps an existing value).

**Increment sanity clamp** (`internal/writers/increment_clamp.go`, `INCREMENT_SANITY_CLAMP_ENABLED`),
for the three production counters, per `(id_equipment, counter)` stream:

1. **Spike floor**: if the absolute totalizer ≥ `SPIKE_FLOOR` (1000) and the increment ≥
   `SPIKE_FRACTION` (0.5) × absolute, write 0 and record the event. This catches increments
   computed from a zero or stale baseline, with or without a rated speed.
2. **Rate bound**: if `equipments.production_speed` is set, write 0 when the increment exceeds
   `K × speed × Δt/60 s`, with Δt from the previous sample on that stream, floored at
   `MIN_DT_SECONDS`.
3. If a count was clamped, or the derived `speed` exceeds `K × production_speed`, the speed is
   written as NULL so the upsert keeps the previous speed.

The clamp's last-seen timestamps are in memory: the first sample after a restart has no Δt and is
only checked by the spike floor. Bronze always receives the raw, unclamped value.

### Scheduled jobs

Every job runs through `jobs.Loop`: the first tick fires after a deterministic 0–44 s stagger, then
every interval. A tick has a deadline of `max(2 × interval, 5 min)` unless set, panics are recovered,
and each tick increments `oeecloud_worker_job_ticks_total{job,outcome}` with `ok`, `error`,
`timeout` or `panic`.

| Job label | Interval | Gate (staging) | What one tick does |
|---|---|---|---|
| `runtime-rollup` | 1 min (fixed) | `RUNTIME_ROLLUP_ENABLED` (on) | `RunHour` → `RunDay` → `RunShift` → `RunGrains` (week, month) → `RunEntityGrains` (area/site) → `RunDQScan` → `RunSilverClamp` → `RunUnmetered`, for each destination. Deadline 5 min for the whole chain |
| `runtime-rollup-hour-backfill` | `ROLLUP_BACKFILL_INTERVAL_SECONDS` (7 s) | `RUNTIME_ROLLUP_ENABLED` and `ROLLUP_BACKFILL_ENABLED` (on) | recompute up to `ROLLUP_BACKFILL_LIMIT` (50) flagged hour rows older than 65 min and newer than 10 days |
| `runtime-provision` | `RUNTIME_PROVISION_INTERVAL_HOURS` (6 h) | `RUNTIME_PROVISION_ENABLED` (on) | call 10 `piot_create_*_oee_*` DB functions that pre-create future grain rows; deadline 30 min |
| `po-runtime-refresh` | `PO_RECALC_INTERVAL_MINUTES` (1) | `PO_RECALC_ENABLED` (on) | `RunCompute` (PO runtime rows) → `RunRecalc` (PO headline OEE) → `uns.RefreshCurrentJobs` |
| `provisional-speed-inference` | 1 h (fixed) | `PROVISIONAL_SPEED_INFERENCE_ENABLED` (off) | set `production_speed` of opted-in lines to the p95 of productive per-minute counts; deadline 10 min |
| `uns-refresh` | `UNS_INTERVAL_MINUTES` (5) | `UNS_REFRESH_ENABLED` (on) | provision UNS rows (first tick, then about hourly), refresh area/site live day/shift, equipment week/month, equipment shift/day |
| `uns-current-metrics` | `UNS_CURRENT_METRICS_INTERVAL_MINUTES` (1) | `UNS_CURRENT_METRICS_ENABLED` (on) | rebuild `equipment_live_metrics` (live state/speed; lines borrow their lead machine's signal) |
| `events-deriver` | `EVENTS_DERIVER_INTERVAL_MINUTES` (1) | `EVENTS_DERIVER_ENABLED` (on) | state transitions → interval events for `status_type = 4` equipment and `EVENTS_WIDEROW_STATE_ENTERPRISES` machines |
| `cpac-events-deriver` (shadow) | `CPAC_EVENT_DERIVATION_INTERVAL_MINUTES` (1) | `CPAC_EVENT_DERIVATION_ENABLED` (host `.env`) | count-silence stops for `CPAC_EVENT_ENTERPRISES` into `CPAC_EVENT_TARGET_TABLE` (shadow table) |
| `cpac-events-deriver` (live) | same | `CPAC_EVENT_DERIVATION_ENABLED` and `CPAC_EVENT_LIVE_ENTERPRISES` (`5`) | same logic, into the live `equipment_events`. Both instances share the job label |
| `events-close-stale` | `EVENTS_CLOSE_STALE_INTERVAL_SEC` (60 s) | `EVENTS_CLOSE_STALE_ENABLED` (on) | close open events of `EVENTS_CLOSE_STALE_ENTERPRISES` (`3,4,5,2000003`) |
| `shift06` | `SHIFT06_INTERVAL_MINUTES` (15) | `SHIFT06_REPORT_ENABLED` (on) | enterprise 6 shift report delete-and-reload (`customer_reports`) |
| `sap13` | `SAP13_INTERVAL_MINUTES` (15) | `SAP13_REPORT_ENABLED` (on) | enterprise 13 SAP data-sync upsert |
| `sync06` | `SYNC06_INTERVAL_MINUTES` (15) | `SYNC06_REPORT_ENABLED` (on) | enterprise 6 production data sync state machine (`serving.data_sync`) |
| `boxes-bridge` | 1 min (fixed) | `BOXES_BRIDGE_ENABLED` (on) | box-scan counts → a target machine's `net_production_incr`, driven by `box_production_bridges` rows |
| `boxes` | `BOXES13_INTERVAL_MINUTES` (5) | `BOXES13_REPORT_ENABLED` (on) | label-scanner aggregation into `customer_reports.boxes` (descriptor-driven) |

Non-job loops: tenant re-discovery (`TENANT_DISCOVERY_INTERVAL_SECONDS`), resolver caches (5 min),
shift-resolver cache (5 min). At boot the worker also calls
`_timescaledb_functions.start_background_workers()` on the analytics DB so continuous-aggregate
refresh policies are running.

### Grain rollups (summary)

The full statement-by-statement walkthrough is in
[stream-engine rollup internals](stream-engine-rollup-internals.md). In short:

- Every grain row has a `recalc_needed` flag. Ingest does not set it; each job **re-flags** a recent
  band every tick (hour: trailing 2–3 h; shift: `[now−12h, now+18h]`; day: current production
  day; week/month: current bucket) and processes flagged rows in its window.
- **Hour** (lines and sectors only, `tp_equipment > 1`): counts from `equipment_categorical_1hour`,
  speed from `_1min`, availability from overlapping `equipment_events` (an open event ends at the
  next event, or at the last observed data + 1 h, never later than now).
- **Day** sums hour rows by production day. **Week/month** sum day rows. **Area/site** sum lines.
- **Shift** is computed directly from the hourly cagg and events, bounded to `ROLLUP_SHIFT_LIMIT`
  rows per tick, ordered `computed_at NULLS FIRST, ts_value` (fair order, #1467).
- Flag-gated passes: counters-only availability (per equipment), **line-lead** (per enterprise),
  availability floor, canonical A·P·Q reconcile.

### Line-lead

For enterprises in `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` (staging `3,5,2000003`; the
`compose.production.yml` stack uses `3`), each `tp_equipment = 3` line with a `lead_machine` gets
its hour and shift row from its member machines instead of its own (usually empty) counters:

| Column source | Rule |
|---|---|
| gross | `equipments.gross_machine`, else `lead_machine`; counter `ProdConsumedCount` unless `gross_counter = 'processed'` |
| net | `equipments.net_machine`, else `lead_machine`; counter `ProdProcessedCount` unless `net_counter = 'consumed'` (#1461, #1463, #1464) |
| scrap | `equipments.scrap_machine` `ProdDefectiveCount`, else none |
| running time | sessionize the lead's productive minutes (any of gross/net/scrap > 0) with gap `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS`; each session runs from its first minute to last minute + timeout |
| planned downtime | overlap of the **line's** planned events with the bucket (event ends at the next event; `ts_end` only as fallback) — #1470, 2026-09-28 |
| available time | bucket − planned downtime |
| ideal speed | lead machine's `production_speed`, else the row's `ideal_speed` |

Counter reconciliation per bucket (hour) or per hour bucket inside the shift:

| Reported | gross | net |
|---|---|---|
| gross ≥ net > 0 | gross | net |
| gross > 0 but **gross < net** | net + scrap (the gross meter undercounts; #1472) | net |
| net and scrap, no gross | net + scrap | net |
| gross and scrap, no net | gross | gross − scrap |
| net only | net | net |
| gross only | gross | gross |

The shift total is the sum of per-bucket values with `net ≤ gross` per bucket, so the shift equals the
sum of its hours. Before #1472 a gross reading below net clamped net down and lost real output
(~87k units on CPACK POLYTYPE2 in 7 days). Before #1470 planned downtime was hard-coded to 0 on
line-lead rows, so every planned stop counted as downtime and CPACK line OEE read 10–50% below
legacy from ~2026-08-31. Line-lead is the single writer of these rows. It is mutually exclusive, per
enterprise, with the per-equipment counters-only availability fallback.

### Events

| Writer | Scope | Input | Output |
|---|---|---|---|
| Ingest mint | `status_type = 4`, shadow `source_type` | each `StateCurrent` sample | open row per sample in `equipment_events` |
| `events-deriver` | `status_type = 4` (+ wide-row enterprises' machines) | `ca_discrete_changes_1s`, last 25 h | gaps-and-islands transitions; upsert `(id_equipment, ts_event)` with `ts_end = next transition`; deletes non-supported rows of the last day unless `forced_creation_system` |
| `cpac-events-deriver` | `status_type = 0`, `tp_equipment IN (1,3)`, listed enterprises | productive minutes in `equipment_categorical_1min`, last 25 h | status 6 at session start, status 10 at last count + threshold (`stop_threshold_time`, else `CPAC_STOP_THRESHOLD_DEFAULT_SEC`); never overwrites or deletes a row an operator touched |
| `events-close-stale` | `status_type = 0` enterprises in the list | open events | see below |

**Closer** (`internal/events/closer.go`), in one transaction with
`timescaledb.max_tuples_decompressed_per_dml_transaction = 0` (the table is compressed):

1. Events with `ts_event` in the last `EVENTS_CLOSE_STALE_HORIZON_HOURS` (72): if a later event
   exists, set `ts_end` to the successor's start. Since #1471 (2026-09-28) this **rebinds** rows
   that were already closed at a different time: a late-arriving event, or an earlier count-silence
   close, had left rows zero-length or overlapping their successor, and the old `ts_end IS NULL`
   guard made that permanent (~350 h of CPACK downtime lost in 14 days).
2. The trailing open **running** event (status 6) with no successor closes at
   `max(ts_event, last productive minute + threshold)` once that time has passed. Open **stops** stay
   open until a successor appears (before 2026-09-24 they were truncated, 955 of 3 791 CPACK stops).
   This trailing close skips rows an operator justified.
3. Long-open pass: open events older than the horizon but within
   `EVENTS_CLOSE_STALE_LONG_HORIZON_DAYS` (60) close at their successor.

Updates match on the true key `(id_equipment, ts_event)`; `id_equipment_event` is not unique (the
sandbox twin reuses CPACK ids).

On staging, CPACK (ent 3) events come from the legacy platform through the legacy replicator
([analytics-sync](analytics-sync.md), part of the [legacy bridge](../subsystems/legacy-bridge.md));
Bispharma (ent 5) events are minted live by the CPAC deriver; the closer bounds both. The code
comments still call the CPACK source "the mirror fan-out" ([mirror-worker](mirror-worker.md), retired
2026-08-13).

### Production orders

`po-runtime-refresh` (`internal/rollup/compute.go`, `recalc.go`), window `PO_RECALC_WINDOW`
(`1 month`), for `production_orders_runtime` rows overlapping the window and flagged
`recalc_needed`:

1. **Events** (runs first so Phase A cannot shrink its set): running = status 6 overlap, stopped =
   status 5/10/11 overlap, from `COALESCE(gross_machine, id_equipment)`; running capped at the PO's
   wall-clock span.
2. **Availability** (`PO_AVAILABILITY_ENABLED`, on): `planned_downtime` and
   `available_time = span − planned`.
3. **Line-lead values** for line-lead enterprises: per-minute reconciled gross/net from the lead
   sources (like the hour grain).
4. **Values**: sums of `silver.equipment_values` increments from `COALESCE(gross_machine,
   id_equipment)`; clears `recalc_needed`. Per-PO `LATERAL … OFFSET 0` so each PO uses an index
   range scan (#1465: 40.5 s → 1.0 s).
5. Re-flag open runtimes and ones that ended within 48 h.
6. **Recalc**: `production_orders` headline OEE (quality = net/gross, availability =
   running/available, oee = net / ((total − planned)/60 × ideal speed), performance =
   oee / (A·Q)), excluding `PO_RECALC_EXCLUDED_ENTERPRISES` (`6`). Running POs (status 2) and POs
   finished in the last 48 h are re-flagged every pass.
7. `uns.RefreshCurrentJobs` updates `equipment_live_job` (running PO per equipment).

PO lifecycle writes (start/end/pause/resume, create, justify, split, setup) come from
`internal/pocontrol` on the ingest path. A failed PO command is logged, counted and **dropped**,
never retried, because the runtime insert has no conflict guard.

### Silver clamp, DQ scan, unmetered, inference

- **DQ scan** (`dq.go`, `DQ_ALARMS_ENABLED`, default on): reads up to 20 000 recent rows per grain
  (shift 30 d, hour 10 d, day 30 d, week 180 d, month 365 d) and upserts `data_quality_event` rows for
  `OEE_GT_1`, `NET_GT_GROSS`, `NEGATIVE_METRIC`, `IDEAL_SPEED_NULL_WHILE_PRODUCING`,
  `IDEAL_SPEED_TOO_LOW`. Changes no served value.
- **Silver clamp** (`silver.go`, `SILVER_CLAMP_ENABLED`, default on): on genuine violators only,
  clamps factors to [0, 1], lowers `net` to `gross`, floors negatives at 0, and writes an
  `INVARIANT_CLAMPED_*` event for each change. A clean tick writes nothing; a non-zero count logs
  "silver invariant clamp CHANGED gold rows (regression tripwire)".
- **Unmetered** (`unmetered.go`): machine rows (`tp_equipment = 1`) of enterprises **not** in
  `ROLLUP_MACHINE_LEVEL_ENTERPRISES` get NULL OEE ("not metered") instead of a flat 0.
- **Provisional speed inference** (`inferspeed.go`, off): only fills `production_speed` that is NULL
  or marked `production_speed_source = 'inferred'`; never overwrites a client-confirmed value.

### Locks and concurrency

| Lock (`pg_*advisory*` on `hashtextextended(key, 0)`) | Taken by | Mode |
|---|---|---|
| `<dest>:runtime` | `RunHour`, `RunDay`, `RunShift`, `RunSilverClamp`, `RunUnmetered` | `pg_try_advisory_xact_lock`: if held, commit and skip the tick |
| `<dest>:runtime` | `RunProvision` | `pg_advisory_lock` (blocking, session) for the whole provisioning pass |
| `<dest>:runtime-backfill` | `RunHourBackfill` | try, transaction-scoped |

`<dest>` is `packiot_analytics` on staging. While provisioning holds the lock (it can take many
minutes), the live hour/day/shift passes skip; flagged rows wait. The backfill has its own key
because the live availability pass held the shared key ~96% of the time and starved it
(2026-08-24); the two write disjoint hour rows (the 65-minute boundary). The live hour cascade to
`equipment_oee_daily` uses `FOR UPDATE SKIP LOCKED` to avoid a deadlock with the backfill
(2026-09-24). `RunGrains`, `RunEntityGrains` and `RunDQScan` take no lock.

The analytics pool connects directly to the database because provisioning needs a session-scoped
lock and `SET statement_timeout = 0` on its connection, which `pgbouncer` in transaction mode would
break.

## Configuration

Defaults are from `internal/config/config.go`. Staging values are from `compose.staging.yml`; "—"
means not set there (code default, unless the host `/opt/packiot/.env` overrides it; that file is
not in git).

### Connectivity and ingest

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `AWS_REGION` | `us-east-1` | `us-east-1` | |
| `PG_SECRET_ID` | `packiot/staging/db` | same | DB credentials (Secrets Manager) |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-stream-engine-creds` | same | AMQP credentials |
| `CREDS_SOURCE` | unset | `env` | `env` = take DB creds from `DB_HOST/PORT/USER/PASSWORD/NAME` and AMQP creds from `RABBITMQ_USER/PASSWORD` instead of Secrets Manager |
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` | – | DB EC2 direct, 5432, from `.env`, `packiot_analytics` | used with `CREDS_SOURCE=env` |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / 5672 | same | |
| `SOURCE_EXCHANGE` | `oee` | `oee` | |
| `WORKER_QUEUE` | `stream-engine-q` | same | queue name prefix |
| `RETRY_EXCHANGE` / `RETRY_QUEUE` | `oee-retry` / `stream-engine-q-retry-30s` | same | |
| `FAILED_EXCHANGE` / `FAILED_QUEUE` | `oee-failed` / `stream-engine-q-failed` | same | |
| `RETRY_TTL_MS` / `MAX_RETRIES` | 30000 / 5 | same | |
| `PREFETCH` | 50 | 50 | unacked messages per queue |
| `CONSUME_LANES` | 1 | 4 | lanes per queue (by `source_type`) |
| `TENANT_DISCOVERY_INTERVAL_SECONDS` | 60 | 60 | 0 = boot only |
| `WORKER_TENANT_ALLOWLIST` | empty (all) | `cpack,sbxcpack,bispharmastaging` | tenants that get queues |
| `WORKER_POOL_SAC_ENABLED` | `false` | `false` | single-active-consumer queues (needs migration) |
| `LEGACY_INGEST_ENABLED` | `true` | `true` | consume per-tenant queues + retry unparseable bodies |
| `HEALTH_PORT` | 9101 | 9101 | |
| `LOG_LEVEL` | `info` | `info` | |
| `POSTGRES_ANALYTICS_DB_NAME` | empty | `packiot_analytics` | enables the analytics pool and the medallion route |
| `POSTGRES_MAX_CONNS` / `POSTGRES_ANALYTICS_MAX_CONNS` | 5 / 15 | 5 / 15 | pool sizes |
| `SHIFT_RESOLVER_ENABLED` | `false` | `true` | fill shift columns on write |
| `SHIFT_FILL_FOLDED` | `false` | `true` | shift columns inside the upsert (one statement, not two) |
| `BRONZE_RAW_APPEND` | `false` | `true` | append raw samples to Bronze |
| `INCREMENT_SANITY_CLAMP_ENABLED` | `false` | `true` | see the clamp above |
| `INCREMENT_SANITY_CLAMP_K` | 4.0 | — | rate bound factor |
| `INCREMENT_SANITY_CLAMP_MIN_DT_SECONDS` | 60 | — | Δt floor |
| `INCREMENT_SANITY_CLAMP_SPIKE_FLOOR` | 1000 | — | minimum absolute for the spike check |
| `INCREMENT_SANITY_CLAMP_SPIKE_FRACTION` | 0.5 | 0.5 | |
| `PO_CONTROL_ENABLED` | `false` | `true` | PO lifecycle parameters on the ingest path |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | `http://tempo:4317` | tracing |
| `BAKE_ENTERPRISE_IDS` | `3` | — | enterprises checked by `--identity-sentinel` |
| `OEECLOUD_WORKER_REPLICAS` (compose) | 1 | — | replicas; >1 needs SAC queues and no static IP/name |

### Rollups and OEE

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `RUNTIME_ROLLUP_ENABLED` | `false` | `true` | the `runtime-rollup` job |
| `ROLLUP_SHIFT_LIMIT` | 300 | 75 | shift rows per tick |
| `ROLLUP_BACKFILL_ENABLED` | `true` | `true` | hour backfill job |
| `ROLLUP_BACKFILL_LIMIT` | 200 | 50 | hour rows per backfill tick |
| `ROLLUP_BACKFILL_INTERVAL_SECONDS` | 30 | 7 | |
| `ROLLUP_MACHINE_LEVEL_ENTERPRISES` | `6` | — | enterprises whose machines get shift OEE (others: "not metered") |
| `RUNTIME_PROVISION_ENABLED` / `RUNTIME_PROVISION_INTERVAL_HOURS` | `false` / 6 | `true` / — | |
| `DQ_ALARMS_ENABLED` | `true` | — | DQ scan |
| `SILVER_CLAMP_ENABLED` | `true` | — | Gold invariant clamp |
| `CHANGEOVER_AVAILABILITY_ENABLED` | `false` | — | count changeover as availability loss instead of planned time |
| `COUNTERS_ONLY_AVAILABILITY_ENABLED` | `false` | `true` | count-based availability for listed machines |
| `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS` | empty | `68,69,70,71,72` (CPACK L6 members) | |
| `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` | 300 | 300 | session gap for all count-based availability |
| `COUNTERS_ONLY_LINE_LEAD_ENABLED` | `false` | `true` | line-lead pass |
| `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` | empty | `3,5,2000003` | unioned at boot with enterprises whose client descriptor asks for line-lead |
| `OEE_AVAIL_FLOOR_ENABLED` | `false` | `true` | raise running time to count-derived active time (listed machines) |
| `OEE_CANONICAL_APQ_ENABLED` | `false` | `true` | store `oee = oee_a·oee_p·oee_q` at every grain |
| `PROVISIONAL_SPEED_INFERENCE_ENABLED` | `false` | — | |
| `PROVISIONAL_SPEED_EQUIPMENTS`, `…_WINDOW_HOURS`, `…_MIN_MINUTES`, `…_PERCENTILE`, `…_FLOOR` | empty, 72, 240, 0.95, 1.0 | — | |

### Events, POs, UNS, reports

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `EVENTS_DERIVER_ENABLED` / `EVENTS_DERIVER_INTERVAL_MINUTES` | `false` / 1 | `true` / — | |
| `EVENTS_EXCLUDED_AREAS`, `EVENTS_EXCLUDED_ENTERPRISES` | empty | — | also used by rollups and UNS |
| `EVENTS_WIDEROW_STATE_ENTERPRISES` | empty | `4` | Incoplast machines derive events from wide-row `state` |
| `CPAC_EVENT_DERIVATION_ENABLED` | `false` | — (host `.env`; must be true for the live ent-5 instance) | |
| `CPAC_EVENT_DERIVATION_INTERVAL_MINUTES` | 1 | — | |
| `CPAC_EVENT_ENTERPRISES` | empty | — (host `.env`, CPACK = 3 per compose comment) | shadow instance scope |
| `CPAC_EVENT_LIVE_ENTERPRISES` | empty | `5` | live instance scope |
| `CPAC_STOP_THRESHOLD_DEFAULT_SEC` | 300 | — | when `stop_threshold_time` is NULL/0 |
| `CPAC_EVENT_TARGET_TABLE` | `equipment_events_cpac_shadow` | — | shadow table |
| `EVENTS_CLOSE_STALE_ENABLED` | `false` | `true` | closer |
| `EVENTS_CLOSE_STALE_INTERVAL_SEC` | 60 | — | |
| `EVENTS_CLOSE_STALE_ENTERPRISES` | empty | `3,4,5,2000003` | any enterprise in a CPAC list must also be here |
| `EVENTS_CLOSE_STALE_THRESHOLD_DEFAULT_SEC` | 300 | — | |
| `EVENTS_CLOSE_STALE_HORIZON_HOURS` / `…_LONG_HORIZON_DAYS` | 72 / 60 | — | |
| `PO_RECALC_ENABLED` / `PO_RECALC_INTERVAL_MINUTES` | `false` / 1 | `true` / — | |
| `PO_RECALC_WINDOW` | `1 month` | — | |
| `PO_RECALC_EXCLUDED_ENTERPRISES` | `6` | — | |
| `PO_AVAILABILITY_ENABLED` | `false` | `true` | PO available/planned time |
| `UNS_REFRESH_ENABLED` / `UNS_INTERVAL_MINUTES` | `false` / 5 | `true` / — | |
| `UNS_CURRENT_METRICS_ENABLED` / `…_INTERVAL_MINUTES` | `false` / 1 | `true` / — | |
| `SHIFT06_REPORT_ENABLED`, `SHIFT06_INTERVAL_MINUTES`, `SHIFT06_CUSTOMER_ID` | `false`, 15, 6 | `true`, 15, — | |
| `SAP13_REPORT_ENABLED`, `SAP13_INTERVAL_MINUTES`, `SAP13_CUSTOMER_ID`, `SAP13_REASONS_FROM_DIM` | `false`, 15, 13, `false` | `true`, 15, —, `false` | |
| `SYNC06_REPORT_ENABLED`, `SYNC06_INTERVAL_MINUTES`, `SYNC06_ENTERPRISE_ID` | `false`, 15, 6 | `true`, —, — | |
| `BOXES13_REPORT_ENABLED`, `BOXES13_INTERVAL_MINUTES` | `false`, 5 | `true`, — | |
| `BOXES_BRIDGE_ENABLED` | `false` | `true` | |

!!! warning "Unverified: which RabbitMQ user staging uses"
    Staging sets `CREDS_SOURCE=env`, so the worker reads `RABBITMQ_USER` / `RABBITMQ_PASSWORD`
    from the host `.env` and ignores `RABBITMQ_SECRET_ID`. The deploy workflow treats
    `RABBITMQ_USER` in that file as the broker admin, and `internal/secrets/secrets.go` documents
    `CREDS_SOURCE=env` as dev-only. If both hold, staging stream-engine connects as the admin user
    rather than the least-privilege `stream-engine` user. Check the live connection's user in the
    RabbitMQ management UI.

## Data & invariants

- **Silver is idempotent.** Every ingest write is an upsert keyed `(ts_value, id_equipment)` (or
  `(id_equipment, ts_event)` for events), so retries and duplicate deliveries do not change Silver.
  Bronze is append-only and does record duplicates.
- **Unregistered topics are skipped, never retried** (a missing `packml_register` row cannot appear
  through retry); they are counted per tenant.
- **Tenant fence**: the equipment id always comes from the resolver for the message's own topic; the
  tenant is the topic's first segment.
- **Physical bounds** at every grain: running/stopped/downtime ≤ bucket length; day sums ≤ the real
  (DST-aware) production-day length; OEE factors in [0, 1]; `net ≤ gross` (Silver clamp, with a DQ
  event).
- **Single writer per cell**: line-lead writes tp=3 rows of its enterprises; counters-only availability
  writes the listed machines; the closer only sets `ts_end`; the CPAC deriver never touches
  operator-edited events.
- **Canonical OEE** (`OEE_CANONICAL_APQ_ENABLED`): after each pass, `oee = oee_a × oee_p × oee_q`
  with each factor clamped, so the headline always equals the product.
- **Lineage**: hour, shift, day, week and month rows carry `computed_at` and `source_watermark`.

## Observability

| Metric | Meaning |
|---|---|
| `oeecloud_worker_amqp_deliveries_total{routing_key,result}` | `acked`, `nacked_retry`, `exhausted_failed` |
| `oeecloud_worker_handler_duration_seconds{routing_key}` | time per delivery |
| `oeecloud_worker_batch_writes_total{dest,tenant,result}` | statements per destination and tenant (`ok`, `error`, `empty_batch`) |
| `oeecloud_worker_job_ticks_total{job,outcome}` | every scheduled job |
| `packml_unresolved_topic_total{tenant}` | metrics skipped for an unregistered topic |
| `oeecloud_worker_amqp_{delivered,acked,nacked_retry,published_to_failed}_total`, `oeecloud_worker_po_control_ops_total` | cumulative counters |

`/health` (port 9101) returns the consumer snapshot plus writer stats (`po_parameter`, `sparkplug`
counters such as `sparkplug_double_encoded_dropped`). `healthy` means the AMQP connection is up.

Alerts in `monitoring/prometheus/rules.yml`: `EngineJobErrorStreak` (> 2 job errors in 15 min),
`EngineStalled` (no job ticks in 15 min), `IngestSilent`, `WritePathDry`, `BatchWriteErrors`,
`ClientIngestStopped`, `PackmlUnroutableTopic`.

Log lines to grep: `runtime-rollup-shift draining backlog`, `job tick TIMED OUT`,
`hour-backfill drained a batch`, `silver invariant clamp CHANGED gold rows`,
`equipment_values: topic not registered, skipping (sampled 1/32)`,
`increment sanity clamp REJECTED`, `stale-open events closed`, `tenant allowlist applied`.

Quick SQL checks (analytics DB):

```sql
-- live shift row computed recently? (use the row where ts_value <= now() < ts_end)
SELECT id_equipment, ts_value, ts_end, computed_at, oee
  FROM gold.equipment_oee_shift
 WHERE ts_value <= now() AND now() < ts_end ORDER BY computed_at NULLS FIRST LIMIT 20;
-- backlog per grain
SELECT count(*) FROM gold.equipment_oee_hourly
 WHERE recalc_needed AND ts_value >= now() - interval '10 days';
```

## Failure modes

| Failure (date) | Symptom | Cause | Fix |
|---|---|---|---|
| Live shift starved (to 2026-09-28) | current-shift OEE and counts 0 all day; daily totals correct | oldest-first `LIMIT 75` against a 127-row recurring re-flag set | #1467 fair order (`computed_at NULLS FIRST`) |
| Line-lead planned downtime ignored (~08-31 → 09-28) | CPACK line OEE 10–50% below legacy | line-lead hard-coded `planned_downtime = 0` | #1470 (live), #1473 (backfill) |
| Gross below net (to 09-28) | line net lower than legacy | net clamped down to an undercounting gross meter | #1472 `gross = net + scrap` |
| Closer truncation (to 09-28) | zero-length or overlapping stops | `ts_end IS NULL` guard froze early closes | #1471 rebind by successor |
| Shift tick over deadline (2026-09-21 → 09-22) | Mission Control all zero platform-wide | Bispharma joined line-lead; shift line-lead took ~205 s of a 300 s deadline; the whole shift transaction rolled back every tick | `ROLLUP_SHIFT_LIMIT` 300 → 75 (#1380); line-lead CTEs `MATERIALIZED` (09-24, 104 s → 5–8 s) |
| Backfill over deadline (2026-09-24) | `hour-backfill line-lead: timeout` every tick | 200 line hours per tick | `ROLLUP_BACKFILL_LIMIT=50` |
| Hour reflag deadlock (2026-09-24) | `40P01` 1–2×/h | lock-order inversion between live cascade and backfill | `FOR UPDATE SKIP LOCKED` in the live path |
| Idle-in-transaction connection (2026-09-25) | shift ticks blocked for 15 min | a stream-engine connection held locks after a job deadline | terminated manually; root cause (rollback with a cancelled context) open |
| Stale opens blanket availability (2026-08-24) | idle lines at ~100% availability; 15 k CPACK opens | closer failed every tick on compressed-chunk decompression limit (`53400`) | `SET LOCAL … max_tuples_decompressed_per_dml_transaction = 0` |
| Frozen cagg watermark (2026-09-07, production) | CPACK OEE stale since Sept 1; 300 s timeouts | continuous aggregates had no refresh policy | refresh + add policies (see [Timescale jobs](timescale-jobs-and-retention.md)) |
| Stale-baseline spikes (2026-09-07) | gross 30–60× | clamp only caught `incr == val` | spike fraction 0.5 (PR #1125) |
| Scope mismatch mint vs deriver (2026-07-09) | week `running_time` 4.95e9, int overflow | per-sample open events minted for `status_type != 4` | mint gated on `status_type = 4` |
| Poison storm (2026-07-12) | worker flooded by nack-retry | non-numeric Incoplast value retried forever | non-numeric values skipped |
| Machine hour phantom backlog (2026-09-10) | 6 276 `recalc_needed` machine hours never draining | re-flag included `tp_equipment = 1` | re-flag scoped to `tp_equipment > 1` |

## Operating it

- **Deploy / restart**: normal staging deploy. A restart loses the clamp's last-seen timestamps and the
  resolver caches; nothing else is stateful in memory. Job first ticks are staggered over 45 s.
- **Onboard a tenant**: active `packml_register` rows + add the lowercased Sparkplug group to
  `WORKER_TENANT_ALLOWLIST`; if counters-only and line-metered, add the enterprise to
  `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` and set `lead_machine` / `gross_machine` / `net_machine` on the
  lines; if it gets CPAC-derived events, add it to both the CPAC list and
  `EVENTS_CLOSE_STALE_ENTERPRISES`. See `services/stream-engine/docs/onboarding-new-tenant.md`.
- **Recompute history**: re-flag rows and let the jobs drain them. Rules and windows are in
  [rollup internals — recomputing history](stream-engine-rollup-internals.md#recomputing-history-safely).
- **Safe**: toggling flag-gated passes by env + recreate; lowering batch limits. **Unsafe**: running
  a second replica without SAC queues (two consumers per tenant queue break ordering); editing grain
  rows by hand while a tick runs (no lock is taken by ad-hoc SQL); enabling the CPAC live deriver for a
  tenant that already has another event writer (double events).
- **Parity tool**: `cmd/port-parity` and `scripts/parity-check.sql` compare the Go SQL with the legacy
  engine; the identity sentinel runs in the staging deploy.

## Tests

- Unit: `cd services/stream-engine && go test ./...` (CI: `go-services.yml`, `-race`).
- Golden fixtures against a real Postgres:
  `DATABASE_URL=postgres://… go test -tags golden -run Golden ./internal/rollup/ ./internal/events/`
  (CI job `golden-fixtures`, `postgres:15`). Includes `TestGoldenShiftBatchFairness`,
  `TestGoldenLineLeadNetMachine`, line-lead, counters-avail, changeover, silver clamp, unmetered,
  hour deadlock, closer golden tests.

## Source map

| Path | What's there |
|---|---|
| `services/stream-engine/cmd/oeecloud-worker/main.go` | wiring of every loop and flag |
| `services/stream-engine/internal/config/config.go` | all env variables and defaults |
| `services/stream-engine/internal/amqp/` | topology, consumer, lanes |
| `services/stream-engine/internal/handlers/sparkplug.go` | ingest handler, routing by `source_type` |
| `services/stream-engine/internal/writers/` | Silver/Bronze SQL, increment clamp |
| `services/stream-engine/internal/sparkplug/` | envelope parse, resolver |
| `services/stream-engine/internal/shiftresolver/resolver.go` | shift column fill |
| `services/stream-engine/internal/rollup/` | `hour.go`, `day.go`, `shift.go`, `grains.go`, `entity_grains.go`, `line_lead.go`, `availability.go`, `backfill.go`, `provision.go`, `compute.go`, `recalc.go`, `dq.go`, `silver.go`, `unmetered.go`, `inferspeed.go`, `locks.go`, `oee.go` |
| `services/stream-engine/internal/events/` | `deriver.go`, `cpac_deriver.go`, `closer.go` |
| `services/stream-engine/internal/pocontrol/` | PO lifecycle |
| `services/stream-engine/internal/uns/` | UNS live tables |
| `services/stream-engine/internal/reports/` | customer report writers |
| `services/stream-engine/internal/jobs/jobs.go` | job loop |
| `services/stream-engine/docs/` | onboarding and scaling strategies (A, C, D) |
| `compose.staging.yml`, `compose.production.yml` | deployed configuration |
| `docs/adr/0014-extract-oee-math-from-database-to-app.md`, `0036-data-architecture-medallion.md`, `0037-oee-correctness-remediation.md`, `0049-oee-correctness.md` | design decisions |
