---
title: stream-engine
layer: 3
owner_area: compute
last_verified: 2026-10-13
---
# stream-engine

> **Layer 3 · Component** — the Go worker that writes ingested Sparkplug envelopes into Bronze and
> Silver and runs every scheduled OEE job (rollups, events, production orders, UNS live tables,
> customer reports). For engineers changing OEE math, adding a tenant, or debugging stale numbers.
> Up: [Compute subsystem](../subsystems/compute.md) · also the AMQP consumer of the
> [ingestion subsystem](../subsystems/ingestion.md) ·
> [README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/stream-engine/README.md)
> (how to run and change it) · [service catalog](../../reference/service-catalog.md)

## Responsibility

stream-engine is accountable for **turning raw counter/state samples into the OEE numbers the
product serves**. It has two halves in one process:

1. **Ingest consumer**: reads envelopes from RabbitMQ, resolves each Sparkplug topic to an
   equipment through `packml_register` (or, for switched tenants, the decoder's birth-bound id),
   and writes `bronze.equipment_values_raw` (append-only) and `silver.equipment_values` (one row
   per equipment-second), plus a few side tables.
2. **Scheduled jobs**: about 17 ticker loops that compute the `gold.equipment_oee_*` grains from
   Silver, continuous aggregates and `silver.equipment_events`, derive and close events, compute
   production-order runtime, refresh the UNS live tables, clear stranded recalc flags and write
   customer report pools.

It runs on **staging** (the new stack). `compose.production.yml` also defines it, but the new-stack
production is not promoted; production clients are still served by the legacy platform.

The code started as a port of the legacy Node-RED `oeecloud` flow and the PL/pgSQL OEE engine
(ADR-0014), which is why many comments say "prod-verbatim" or "parity". The binary is
`stream-engine`; its main package, metric names (`oeecloud_worker_*`) and network alias
(`oeecloud-worker`) keep the old name. It serves no API beyond `/health` and `/metrics`, so it has
no API reference page.

## At a glance

| | |
|---|---|
| Language / runtime | Go 1.25, distroless, `pgx/v5`, `amqp091-go` |
| Repo path | `services/stream-engine` (main: `cmd/oeecloud-worker/main.go`) |
| Compose service | `stream-engine` (`compose.staging.yml`), container `stream-engine`, IP `172.18.0.20`, alias `oeecloud-worker` |
| Image | built on deploy from `services/stream-engine/Dockerfile`, entrypoint `/usr/local/bin/stream-engine` |
| Host (staging) | staging app host; DB connections go **directly** to the DB EC2 (`DB_HOST=10.10.10.89`), not through `pgbouncer` |
| Ports | 9101 `/health`, `/metrics` (in-network only) |
| Limits | `mem_limit: 256m`, `cpus: 0.5`, replicas `${OEECLOUD_WORKER_REPLICAS:-1}` |
| Pools | main pool (`POSTGRES_MAX_CONNS`, 5) + analytics pool (`POSTGRES_ANALYTICS_MAX_CONNS`, 15); on staging both open `packiot_analytics` |
| Depends on (compose) | `rabbitmq` healthy, `pgbouncer` started (not used), `db-migrate` completed |
| Depended on by | everything that reads Silver/Gold: read-api `serving.*`, Superset `bi.*`, Grafana, historian live tier |
| Subcommands | `--healthcheck` (Docker probe), `--identity-sentinel` (staging deploy gate: no `running_time` above 1.05 × bucket span for `BAKE_ENTERPRISE_IDS`) |
| Related tools | `cmd/port-parity` (Go SQL vs legacy engine), `cmd/recompute-render` (renders the history-recompute SQL from the engine's own passes) |

## Inputs & outputs

### Ingest path (per AMQP message)

| Reads | Writes (staging schemas) |
|---|---|
| Queue `stream-engine-q-<tenant>` per discovered tenant (key `sparkplug.data.<tenant>`) and the firehose `stream-engine-q` (key `sparkplug.data`), exchange `oee` | `silver.equipment_values` — UPSERT on `(ts_value, id_equipment)` |
| `packml_register` ⨝ `areas` ⨝ `equipments` (resolver, cached) | `bronze.equipment_values_raw` — append (`BRONZE_RAW_APPEND`) |
| `sites`, `equipments`, `shift_hours` (shift resolver, cached) | `silver.equipment_events` — per-sample mint for `status_type = 4` state metrics; `bronze.equipment_events_raw` — append of those mints |
| `core.equipments` by id (birth-bound resolution for `BIRTHBOUND_SWITCHED_ENTERPRISES`) | `silver.equipment_live_metrics` — `CurMachSpeed` metrics |
| | `silver.equipment_values` — parameter 30701 (ideal speed) and 30850 (analogs) |
| | PO lifecycle tables (`core.production_orders`, `gold.production_orders_runtime`, `silver.equipment_live_job`, `silver.equipment_events_man`, `identity.user_logs`, …) — parameters 30700, 30800–30803, 30805, 30810–30814, 30820, 30861, 30862, 30880 when `PO_CONTROL_ENABLED` and the envelope has a `source_type` |
| | `silver.data_quality_event` — `INVARIANT_CLAMPED_INCREMENT`, best-effort |

The destination is chosen by the envelope's `source_type`: `refactored` → the analytics pool with
schemas `silver` / `bronze` / `gold` / `core` / `identity`; empty → the main pool, schema `public`
(the single-flow shape `compose.production.yml` would run, which sets no
`POSTGRES_ANALYTICS_DB_NAME`). `source_type = "go"` envelopes are acked and dropped (retired F2
leg). Since #1574 (2026-10-06) the counter UPSERTs also write exact float8 `*_total` columns next
to the float4 `*_val` totalizers; on the `public` route only when `COUNTER_TOTALS_PUBLIC=true`.

### Background jobs

Read Silver facts, the continuous aggregates `silver.equipment_categorical_1min`,
`silver.equipment_categorical_1hour`, `silver.ca_discrete_changes_1s`, `silver.equipment_events`,
`silver.plc_link_minutes`, `config.equipment_out_of_service`, `core.*` reference tables and
`config.production_targets`. Write `gold.equipment_oee_{hourly,daily,weekly,monthly,shift}`,
`gold.area_oee_{daily,shift}`, `gold.site_oee_shift`, `gold.production_orders_runtime`,
`core.production_orders` OEE columns, `silver.equipment_events` (derivers, closer),
`silver.equipment_live_*` / `silver.area_live_*`, `silver.data_quality_event`,
`customer_reports.*`, and `core.equipments.production_speed` (inference only). The schema layout is
in [analytics DB schemas](analytics-db-schemas.md).

## Internal design

### Packages

| Package | Role |
|---|---|
| `internal/amqp` | topology, consumer, lanes, retry/failed routing, tenant discovery loop |
| `internal/handlers` | dispatcher, `SparkplugHandler` (one `pgx.Batch` per delivery) |
| `internal/writers` | SQL builders: `equipment_values`, `increment_clamp`, `totalizer_seed`, `uns_current_metrics`, `po_parameter` |
| `internal/sparkplug` | envelope parse, metric classification, topic resolver, birth-bound resolution (ADR-0061) |
| `internal/birthverify` | counts birth-bound id vs `packml_register` agreement (`BIRTHBIND_VERIFY`) |
| `internal/shiftresolver` | Go port of the shift trigger (`id_shift`, `id_shift_hour`, `ts_value_production`) |
| `internal/pocontrol` | PO lifecycle state machine (ADR-0010 10.3); client PO number as text (ADR-0062) |
| `internal/rollup` | OEE grains, backfill, provision, availability exclusions, PO compute/recalc, DQ, Silver clamp, stranded-flag sweep, inference, history render |
| `internal/events` | status-4 deriver, count-silence (CPAC) deriver, stale-open closer |
| `internal/uns` | UNS live tables |
| `internal/reports` | customer report writers (enterprises 6 and 13, boxes) |
| `internal/jobs` | the ticker loop used by every job (timeouts, panic recovery, tick metric) |
| `internal/flows` | destination list (one dest: `packiot_analytics`, or `public` when no analytics pool) |
| `internal/oeeprofile` | boot-time load of line-lead enterprises and per-line overrides from `client_descriptors` |
| `internal/bake` | the `--identity-sentinel` check |

### The ingest consumer

1. **Topology** (`internal/amqp/topology.go`): declares `oee`, `oee-retry`, `oee-failed`, the shared
   queue triple and one triple per tenant (`<prefix>-<t>`, `-retry-30s`, `-failed`). The shared
   retry and failed queues are bound to the exact key `sparkplug.data`; any old `#` binding is
   removed at boot (bind first, then unbind, so no gap). Broker-side details are in
   [brokers](brokers.md).
2. **Tenant discovery**: `SELECT DISTINCT lower(split_part(packml_topic,'/',1)) FROM packml_register
   WHERE active`, intersected with `WORKER_TENANT_ALLOWLIST`, at boot and every
   `TENANT_DISCOVERY_INTERVAL_SECONDS`. A new tenant starts consuming without a restart; a tenant
   that disappears stops being consumed (its queue is kept). **This only runs when
   `LEGACY_INGEST_ENABLED=true`** (the name is historical). With it false, no per-tenant queue is
   consumed, which on staging (per-tenant routing) would stop all ingest.
3. **Lanes**: each queue has `CONSUME_LANES` goroutines; a delivery goes to lane
   `hash(source_type) % N`. Staging emits only `refactored`, so all messages of a queue land in one
   lane and each tenant queue is processed serially, in order.
4. **Retry**: a handler error nacks without requeue → `oee-retry` → the queue's `-retry-30s` (TTL
   `RETRY_TTL_MS`) → back to `oee`. Each round trip adds one `rejected` count (on the main queue)
   and one `expired` count (on the retry queue) to the `x-death` header. Only the `rejected` count
   for the queue being consumed is a handler failure, so that is the retry count. A message is
   parked in `oee-failed` once it exceeds `MAX_RETRIES`: with 5, the handler runs six times (one
   first run + five retries).
5. **Handler** (`internal/handlers/sparkplug.go`):
   - Parse the envelope. A JSON string of JSON is dropped (poison guard). Other parse failures are
     retried only if legacy ingest is on.
   - Fill missing or implausible metric timestamps (< 2015-01-01) from the payload timestamp,
     then from now.
   - Birth-bound pass (ADR-0061): count stamp agreement; for switched enterprises, resolve
     counters, state, mode and speed by the decoder's stamped `id_equipment` and quarantine an
     unstamped one (skipped and counted).
   - For each metric, classify by name and build one or more statements into one `pgx.Batch`.
     Unregistered topics are skipped and counted in `packml_unresolved_topic_total{tenant}`.
   - Send the batch in one round-trip. Any statement error → nack → retry (Silver writes are
     upserts, so a retry is safe for Silver; Bronze gets another row).
   - Side-write clamp events to `data_quality_event` after the batch, errors swallowed.
6. **Resolver** (`internal/sparkplug/resolver.go`): topic → `(id_enterprise, id_site, id_area,
   id_equipment, signal_quality, day_begin, status_type, production_speed)`. The lookup key is the
   first five topic segments, or four for a line metric (`…/Sect/{Admin|Status|Command}/…`). Cache
   5 min for hits, 30 s for misses, at most 10 000 entries.

**Silver UPSERT semantics** (`internal/writers/equipment_values.go`): `ts_value` is truncated to
the second. Each counter kind writes its own columns (`net_production_incr/_val/_total` for
processed, `gross_production_*` for consumed, `scrap_*` for defective, `state`, `mode`). On conflict
the increment is **replaced**, not summed: two samples of the same counter within one second keep
only the last increment in Silver; Bronze keeps both. `tp_equipment` is 3 for line topics and 1
otherwise. With `SHIFT_FILL_FOLDED=true` the shift columns ride inside the upsert (`COALESCE` keeps
an existing value).

**Increment sanity clamp** (`internal/writers/increment_clamp.go`, `INCREMENT_SANITY_CLAMP_ENABLED`),
for the three production counters, per `(id_equipment, counter)` stream. The increments are
deltas the decoder computes from its own baseline; a stale or lost baseline turns into one huge
phantom increment. In order:

1. **Spike**: totalizer ≥ `SPIKE_FLOOR` (1000) and increment ≥ `SPIKE_FRACTION` (0.5) × totalizer.
2. **Unbacked increment** (#1544, 2026-10-01): the increment exceeds the totalizer's own movement
   since the previous reading by ≥ 100 units and by more than half the increment. The replacement
   is that movement.
3. **Rate bound**: if `equipments.production_speed` is set, increment > `K` (4) ×
   speed × Δt/60 s, with Δt from the previous sample on that stream, floored at `MIN_DT_SECONDS`.

A rejected increment is replaced by the totalizer's movement when that movement itself passes the
same checks, else 0 (since #1482, 2026-09-29; before, it was always 0 and real production was lost).
A clamped count, or a derived `speed` above `K × production_speed`, writes speed NULL so the upsert
keeps the previous speed. The last-seen timestamps are in memory; the last totalizer is seeded once
per stream from the database after a restart. Bronze always receives the raw value.

### Scheduled jobs

Every job runs through `jobs.Loop`: the first tick fires after a deterministic 0–44 s stagger, then
every interval. A tick has a deadline of `max(2 × interval, 5 min)` unless set, panics are recovered,
and each tick increments `oeecloud_worker_job_ticks_total{job,outcome}` with `ok`, `error`,
`timeout` or `panic`.

| Job label | Interval | Gate (staging) | What one tick does |
|---|---|---|---|
| `runtime-rollup` | 1 min (fixed) | `RUNTIME_ROLLUP_ENABLED` (on) | `RunHour` → `RunDay` → `RunShift` → `RunGrains` (week, month) → `RunEntityGrains` (area/site) → `RunDQScan` → `RunSilverClamp` → `RunUnmetered`. Each step has its own transaction and fails alone; the 5-min deadline covers the chain |
| `runtime-rollup-hour-backfill` | `ROLLUP_BACKFILL_INTERVAL_SECONDS` (7 s) | `RUNTIME_ROLLUP_ENABLED` and `ROLLUP_BACKFILL_ENABLED` (on) | recompute up to `ROLLUP_BACKFILL_LIMIT` (50) flagged hour rows older than 65 min and newer than 10 days |
| `runtime-provision` | `RUNTIME_PROVISION_INTERVAL_HOURS` (6 h) | `RUNTIME_PROVISION_ENABLED` (on) | pre-create future grain rows: hour rows with the engine's `provisionHourlySQL` (production day = the day containing bucket + 59 min, so the run minute does not matter), the other grains with the `piot_create_*_oee_*` DB functions; deadline 30 min |
| `po-runtime-refresh` | `PO_RECALC_INTERVAL_MINUTES` (1) | `PO_RECALC_ENABLED` (on) | propagate header flags → `RunCompute` (PO runtime rows) → `RunRecalc` (PO headline OEE) → closed-row sweep → `uns.RefreshCurrentJobs` |
| `stranded-flag-sweep` | 1 h (fixed) | `STRANDED_FLAG_SWEEP_ENABLED` (default on) and PO recalc or rollup on | clear `recalc_needed` on rows no pass can reach and WARN with counts (#1541) |
| `provisional-speed-inference` | 1 h (fixed) | `PROVISIONAL_SPEED_INFERENCE_ENABLED` (off) | set `production_speed` of opted-in lines to the p95 of productive per-minute counts; deadline 10 min |
| `uns-refresh` | `UNS_INTERVAL_MINUTES` (5) | `UNS_REFRESH_ENABLED` (on) | provision UNS rows, refresh area/site live day/shift, equipment month/shift/day |
| `uns-current-metrics` | `UNS_CURRENT_METRICS_INTERVAL_MINUTES` (1) | `UNS_CURRENT_METRICS_ENABLED` (on) | rebuild `equipment_live_metrics` (live state/speed; lines borrow their lead machine's signal) |
| `events-deriver` | `EVENTS_DERIVER_INTERVAL_MINUTES` (1) | `EVENTS_DERIVER_ENABLED` (on) | state transitions → interval events for `status_type = 4` equipment and `EVENTS_WIDEROW_STATE_ENTERPRISES` machines |
| `cpac-events-deriver` (shadow) | `CPAC_EVENT_DERIVATION_INTERVAL_MINUTES` (1) | `CPAC_EVENT_DERIVATION_ENABLED` and `CPAC_EVENT_ENTERPRISES` (host `.env`) | count-silence stops into `CPAC_EVENT_TARGET_TABLE` (shadow table) |
| `cpac-events-deriver` (live) | same | `CPAC_EVENT_DERIVATION_ENABLED` and `CPAC_EVENT_LIVE_ENTERPRISES` (`5`) | same logic into the live `equipment_events`, plus lead activity and PLC-link awareness (below). Both instances share the job label |
| `events-close-stale` | `EVENTS_CLOSE_STALE_INTERVAL_SEC` (60 s) | `EVENTS_CLOSE_STALE_ENABLED` (on) | close open events of `EVENTS_CLOSE_STALE_ENTERPRISES` (`3,4,5,2000003`) |
| `shift06` | `SHIFT06_INTERVAL_MINUTES` (15) | `SHIFT06_REPORT_ENABLED` (on) | enterprise 6 shift report delete-and-reload (`customer_reports.shift`) |
| `sap13` | `SAP13_INTERVAL_MINUTES` (15) | `SAP13_REPORT_ENABLED` (on) | enterprise 13 SAP data-sync upsert |
| `sync06` | `SYNC06_INTERVAL_MINUTES` (15) | `SYNC06_REPORT_ENABLED` (on) | enterprise 6 production data sync (`serving.data_sync` → `customer_reports.production_data_sync`) |
| `boxes-bridge` | 1 min (fixed) | `BOXES_BRIDGE_ENABLED` (on) | box-scan counts → a target machine's `net_production_incr`, driven by `box_production_bridges` rows |
| `boxes` | `BOXES13_INTERVAL_MINUTES` (5) | `BOXES13_REPORT_ENABLED` (on) | label-scanner aggregation into `customer_reports.boxes` |

Non-job loops: tenant re-discovery, resolver cache (5 min), shift-resolver cache (5 min). At boot the
worker calls `_timescaledb_functions.start_background_workers()` on the analytics DB so the
continuous-aggregate refresh policies run, and loads the OEE profile from `client_descriptors`
once (a profile change needs a restart).

### Grain rollups (summary)

The statement-by-statement walkthrough is in
[stream-engine rollup internals](stream-engine-rollup-internals.md). In short:

- Every grain row has a `recalc_needed` flag. Ingest does not set it; each job **re-flags** a recent
  band every tick (hour: trailing 2–3 h; shift: `[now−12h, now+18h)`; day: current production day;
  week/month: current bucket) and processes flagged rows in its window.
- **Hour** (lines and sectors only, `tp_equipment > 1`): counts from `equipment_categorical_1hour`,
  speed from `_1min`, time in state from overlapping `equipment_events` (an open event ends at the
  next event, or at the last data-bearing hour + 1 h, never later than now).
- **Day** sums hour rows by production day. **Week/month** sum day rows. **Area/site** sum lines.
- **Shift** is computed from the hourly cagg and events, at most `ROLLUP_SHIFT_LIMIT` rows per tick,
  ordered `computed_at NULLS FIRST, ts_value` (fair order, #1467).
- Flag-gated passes: counters-only availability (listed machines), **line-lead** (listed
  enterprises and lines), availability floor, **availability exclusions**, canonical A·P·Q
  reconcile.
- **No caps except availability** (#1482, 2026-09-29): `oee_a` stays in [0, 1]; `oee`, `oee_p` and
  `oee_q` keep only a lower bound of 0. Performance above 1 means the ideal speed is set too low;
  hourly quality above 1 means units in transit between the infeed and outfeed meters. Both are
  stored as measured and the UI decides how to show them.

### Line-lead

For enterprises in `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` (staging `3,5,2000003`; the
`compose.production.yml` stack uses `3`), unioned with enterprises whose client descriptor selects
line-metered availability, minus per-line opt-outs, plus per-line opt-ins (`oee_profile.lines`,
#1500): each `tp_equipment = 3` line with a `lead_machine` gets its hour, shift and PO counters
from its member machines instead of its own (usually empty) counters.

| Column source | Rule |
|---|---|
| gross | `equipments.gross_machine`, else `lead_machine`; counter `ProdConsumedCount` unless `gross_counter = 'processed'` |
| net | `equipments.net_machine`, else `lead_machine`; counter `ProdProcessedCount` unless `net_counter = 'consumed'` |
| scrap | `equipments.scrap_machine` `ProdDefectiveCount`, else none |
| running time | sessionize the lead's productive minutes (gross, net or scrap > 0) with gap `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS`; each session runs from its first minute to last minute + timeout. In an hour where the lead has no productive minute, the gross/net machines' minutes stand in (lead-silent fallback, #1482) |
| planned downtime | overlap of the **line's** planned events with the bucket (event ends at the next event; `ts_end` only as fallback; the event in effect at the scan bound is included) — #1470 |
| available time | bucket − planned downtime (then availability exclusions) |
| ideal speed | lead machine's `production_speed`, else the row's `ideal_speed` |

Counter reconciliation per hour bucket (the shift sums its buckets; boundary hours of a shift that
does not start on the hour are read from the 1-min cagg clipped to the shift, #1545):

| Reported in the bucket | gross | net |
|---|---|---|
| gross and net | gross as measured (also when below net) | net |
| net and scrap, no gross | net + scrap | net |
| gross and scrap, no net | gross | gross − scrap |
| net only | net | net |
| gross only | gross | gross |

`scrap` is stored as `gross − net` and is **signed**: a negative hour is units in transit. When a
line's `fill_missing_meter = false` (report-by-exception totalizers, #1530), a silent meter is 0,
not filled. Before #1482 a gross reading below net was replaced by `net + scrap` (#1472) and per-bucket
`net ≤ gross` clamps inflated gross and scrap over every period. Line-lead is the single writer of
these rows and is mutually exclusive, per enterprise, with the per-equipment counters-only
availability fallback.

### Availability exclusions

`AVAILABILITY_EXCLUSIONS_ENABLED` (default on, #1534, 2026-10-01) adds one step per grain after
every `available_time` writer: time inside an **out-of-service** window
(`config.equipment_out_of_service` on the equipment or an ancestor) or a **no-data** span (status
20 events; a line reads its lead machine's) is removed from `available_time` and recorded in
`out_of_service_time` / `no_data_time`. Out-of-service time is also removed from the target;
no-data time is not. The PO grain gets the same treatment when `PO_AVAILABILITY_ENABLED`.

### Events

| Writer | Scope | Input | Output |
|---|---|---|---|
| Ingest mint | `status_type = 4`, non-empty `source_type` | each `StateCurrent` sample | open row per sample in `equipment_events` |
| `events-deriver` | `status_type = 4` (+ wide-row enterprises' machines) | `ca_discrete_changes_1s`, last 25 h | gaps-and-islands transitions; upsert `(id_equipment, ts_event)`; deletes non-transition rows of the last day unless `forced_creation_system` |
| `cpac-events-deriver` | `status_type = 0`, `tp_equipment IN (1,3)`, listed enterprises | productive minutes in `equipment_categorical_1min`, last 25 h | status 6 at session start, status 10 at last count + threshold (`stop_threshold_time`, else `CPAC_STOP_THRESHOLD_DEFAULT_SEC`); never overwrites or deletes a row an operator touched |
| `cpac-events-deriver` live extras | as above | lead's gross **or** net/scrap (lines with `downtime_from_lead_machine`); `silver.plc_link_minutes` | a PLC-link gap longer than the threshold becomes status **20 (no data)** instead of a stop; a resume without production opens a stop. Link events only for equipment the deriver saw produce in 7 days (#1663) |
| `events-close-stale` | listed enterprises | open events | see below |

**Closer** (`internal/events/closer.go`), in one transaction with
`SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0` (the table is compressed):

1. Events with `ts_event` in the last `EVENTS_CLOSE_STALE_HORIZON_HOURS` (72): if a later event
   exists, set `ts_end` to the successor's start. Since #1471 (2026-09-28) this also **rebinds**
   rows already closed at a different time (late-arriving events had left rows zero-length or
   overlapping; ~350 h of CPACK downtime lost in 14 days).
2. The trailing open **running** event (status 6) closes at `max(ts_event, last productive minute
   + threshold)` once that time has passed. Open **stops** stay open until a successor appears
   (before 2026-09-24 they were truncated). Rows an operator justified are skipped.
3. Long-open pass: open events older than the horizon but within
   `EVENTS_CLOSE_STALE_LONG_HORIZON_DAYS` (60) close at their successor.

Updates match on the true key `(id_equipment, ts_event)`; `id_equipment_event` is not unique (the
sandbox twin reuses CPACK ids).

On staging, CPACK (ent 3) events come from the legacy platform through the legacy replicator
([analytics-sync](analytics-sync.md), part of the [legacy bridge](../subsystems/legacy-bridge.md));
Bispharma (ent 5) events are minted live by the CPAC deriver; the closer bounds both.

### Production orders

`po-runtime-refresh` (`internal/rollup/compute.go`, `recalc.go`), window `PO_RECALC_WINDOW`
(`1 month`), for `production_orders_runtime` rows overlapping the window and flagged
`recalc_needed`. `RunCompute` runs all phases in **one REPEATABLE READ transaction** (#1520,
2026-09-30), so a flag set mid-tick cannot be cleared without its values:

1. **Events**: running = status 6 overlap, stopped = status 5/10/11 overlap, from
   `COALESCE(gross_machine, id_equipment)`; running capped at the PO's wall-clock span.
2. **Availability** (`PO_AVAILABILITY_ENABLED`, on): `planned_downtime`, `available_time = span −
   planned`, minus exclusions.
3. **Line-lead values** for line-lead lines: per-minute lead-sourced gross/net (like the hour grain).
4. **Values**: sums of `silver.equipment_values` increments from `COALESCE(gross_machine,
   id_equipment)`; clears `recalc_needed`. Per-PO `LATERAL … OFFSET 0` (#1465: 40.5 s → 1.0 s).
5. Re-flag open runtimes and ones that ended within 48 h.

Then **Recalc** writes `production_orders` headline OEE (quality = net/gross, availability =
running/available capped at 1, oee = net / ((total − planned)/60 × ideal speed), performance =
oee / (A·Q)), excluding `PO_RECALC_EXCLUDED_ENTERPRISES` (`6`); running POs (status 2) and POs with
status 3/4 that ended in the last 48 h are re-flagged every pass. A **closed-row sweep** re-flags
every closed runtime row in the window once per `PO_RECOMPUTE_SWEEP_HOURS` (24), spread over the
ticks. Finally `uns.RefreshCurrentJobs` updates `equipment_live_job`.

PO lifecycle writes (start/end/pause/resume, create, justify, split, setup) come from
`internal/pocontrol` on the ingest path. A failed PO command is logged, counted and **dropped**,
never retried, because the runtime insert has no conflict guard. Since ADR-0062 P2 (#1623) the
client PO number is written as text (`id_order_text`).

### DQ scan, Silver clamp, unmetered, stranded flags, inference

- **DQ scan** (`dq.go`, `DQ_ALARMS_ENABLED`, default on): reads up to 20 000 recent rows per grain
  (shift 30 d, hour 10 d, day 30 d, week 180 d, month 365 d) and upserts `data_quality_event` rows.
  `OEE_GT_1` now means impossible (availability > 1 or any factor > 10); `NET_GT_GROSS` is skipped at
  the hour grain (transit); plus `NEGATIVE_METRIC`, `IDEAL_SPEED_NULL_WHILE_PRODUCING`,
  `IDEAL_SPEED_TOO_LOW`. Changes no served value.
- **Silver clamp** (`silver.go`, `SILVER_CLAMP_ENABLED`, default on): on rows a clamp would change,
  bounds `oee_a` to [0, 1], floors `oee`/`oee_p`/`oee_q` at 0 (NULL kept), floors negative counts and
  durations at 0 (scrap excluded: it is signed), and writes an `INVARIANT_CLAMPED_*` event per change.
  It no longer lowers `net` to `gross`. A non-zero count logs "silver invariant clamp CHANGED gold
  rows (regression tripwire)".
- **Unmetered** (`unmetered.go`): machine rows (`tp_equipment = 1`) of enterprises **not** in
  `ROLLUP_MACHINE_LEVEL_ENTERPRISES` get NULL OEE ("not metered") instead of a flat 0.
- **Stranded-flag sweep** (`stranded.go`): clears flags on PO runtime rows closed before the window,
  PO headers outside it, shift rows older than 30 days or never in scope, and hour rows older than
  the 10-day backfill horizon or `tp_equipment = 1`. Found 2,058 PO runs, 933 headers and 7,770
  machine shift rows flagged forever (2026-10-01).
- **Provisional speed inference** (`inferspeed.go`, off): only fills `production_speed` that is NULL
  or marked `production_speed_source = 'inferred'`.

### Locks and concurrency

| Lock (`pg_*advisory*` on `hashtextextended(key, 0)`) | Taken by | Mode |
|---|---|---|
| `<dest>:runtime` | `RunHour`, `RunDay`, `RunShift`, `RunSilverClamp`, `RunUnmetered` | `pg_try_advisory_xact_lock`: if held, commit and skip the tick |
| `<dest>:runtime` | `RunProvision` | `pg_advisory_lock` (blocking, session) for the whole provisioning pass |
| `<dest>:runtime-backfill` | `RunHourBackfill` | try, transaction-scoped |

`<dest>` is `packiot_analytics` on staging. While provisioning holds the lock, the live
hour/day/shift passes skip. The backfill has its own key because the live pass held the shared key
~96% of the time and starved it (2026-08-24). The live hour cascade to `equipment_oee_daily` and the
hour re-flag use `FOR UPDATE SKIP LOCKED` to avoid a deadlock with the backfill (2026-09-24).
`RunGrains`, `RunEntityGrains` and `RunDQScan` take no lock.

The analytics pool connects directly to the database because provisioning needs a session-scoped
lock, `SET statement_timeout = 0` and a cross-statement `search_path`, which `pgbouncer` in
transaction mode would break.

## Configuration

Defaults are from `internal/config/config.go` (plus `internal/secrets/` and `internal/tracing/`);
booleans are on only when exactly `true`. Staging values are from `compose.staging.yml`; "—" means
not set there (code default, unless the host `/opt/packiot/.env`, read through `env_file`,
overrides it; that file is not in git).

### Connectivity and ingest

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `AWS_REGION` | `us-east-1` | `us-east-1` | |
| `PG_SECRET_ID` | `packiot/staging/db` | same | DB credentials in Secrets Manager (unused with `CREDS_SOURCE=env`) |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-stream-engine-creds` | same | AMQP credentials (unused when the AMQP source is `env`) |
| `CREDS_SOURCE` | unset | `env` | take DB creds from `DB_*` (and, unless `AMQP_CREDS_SOURCE` says otherwise, AMQP creds from `RABBITMQ_USER/PASSWORD`) instead of Secrets Manager |
| `AMQP_CREDS_SOURCE` | unset (follows `CREDS_SOURCE`) | `aws` | AMQP creds only: `env` = `RABBITMQ_USER/PASSWORD`, anything else = `RABBITMQ_SECRET_ID` |
| `DB_HOST`, `DB_PORT`, `DB_NAME` | `postgres`, 5432, `packiot` | `10.10.10.89`, 5432, `packiot_analytics` | with `CREDS_SOURCE=env` |
| `DB_USER`, `DB_PASSWORD` | – (required) | `${POSTGRES_USER}`, `${POSTGRES_PASSWORD}` from `.env` | |
| `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | – (required in env mode) | unused (`AMQP_CREDS_SOURCE=aws`) | see the note below |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / 5672 | same | |
| `SOURCE_EXCHANGE` | `oee` | `oee` | |
| `WORKER_QUEUE` | `stream-engine-q` | same | firehose queue name and per-tenant prefix |
| `RETRY_EXCHANGE` / `RETRY_QUEUE` | `oee-retry` / `stream-engine-q-retry-30s` | same | |
| `FAILED_EXCHANGE` / `FAILED_QUEUE` | `oee-failed` / `stream-engine-q-failed` | same | |
| `RETRY_TTL_MS` / `MAX_RETRIES` | 30000 / 5 | same | retries after the first run; counted from the `x-death` `rejected` entry of the consumed queue |
| `PREFETCH` | 50 | 50 | unacked messages per queue |
| `CONSUME_LANES` | 1 | 4 | lanes per queue (by `source_type`) |
| `TENANT_DISCOVERY_INTERVAL_SECONDS` | 60 | 60 | 0 = boot only |
| `WORKER_TENANT_ALLOWLIST` | empty (all) | `cpack,sbxcpack,bispharmastaging,incoplast` (overridable from `.env`) | tenants that get queues |
| `WORKER_POOL_SAC_ENABLED` | `false` | `false` | single-active-consumer tenant queues (needs `scripts/migrate-tenant-queues-sac.sh`) |
| `LEGACY_INGEST_ENABLED` | `true` | `true` | consume per-tenant queues + retry unparseable bodies |
| `BIRTHBIND_VERIFY` | `true` | — | count birth-bound id vs `packml_register` agreement (`oeecloud_worker_birthbind_verify_total`) |
| `BIRTHBOUND_SWITCHED_ENTERPRISES` | empty | — | enterprises whose bindable metrics resolve by the decoder's stamped id (ADR-0061 P2c) |
| `HEALTH_PORT` | 9101 | 9101 | |
| `LOG_LEVEL` | `info` | `info` | |
| `POSTGRES_ANALYTICS_DB_NAME` | empty | `packiot_analytics` | enables the analytics pool and the medallion route |
| `POSTGRES_MAX_CONNS` / `POSTGRES_ANALYTICS_MAX_CONNS` | 5 / 15 | 5 / 15 | pool sizes (≤ 20 direct connections) |
| `SHIFT_RESOLVER_ENABLED` | `false` | `true` | fill shift columns on write |
| `SHIFT_FILL_FOLDED` | `false` | `true` | shift columns inside the upsert (one statement, not two) |
| `BRONZE_RAW_APPEND` | `false` | `true` | append raw samples to Bronze |
| `COUNTER_TOTALS_PUBLIC` | `false` | — | also write float8 `*_total` on the `public` route (analytics route always writes them) |
| `INCREMENT_SANITY_CLAMP_ENABLED` | `false` | `true` | see the clamp above |
| `INCREMENT_SANITY_CLAMP_K` | 4.0 | — | rate bound factor |
| `INCREMENT_SANITY_CLAMP_MIN_DT_SECONDS` | 60 | — | Δt floor |
| `INCREMENT_SANITY_CLAMP_SPIKE_FLOOR` | 1000 | — | minimum totalizer for the spike check |
| `INCREMENT_SANITY_CLAMP_SPIKE_FRACTION` | 0.5 | 0.5 | |
| `PO_CONTROL_ENABLED` | `false` | `true` | PO lifecycle parameters on the ingest path |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | `http://tempo:4317` | tracing on when set |
| `OTEL_TRACES_SAMPLER_ARG` | 1.0 | — | parent-based ratio sampler |
| `BAKE_ENTERPRISE_IDS` | `3` | — | enterprises checked by `--identity-sentinel` |
| `OEECLOUD_WORKER_REPLICAS` (compose) | 1 | — | replicas; > 1 needs SAC queues and no static IP/name |

!!! note "Which RabbitMQ user staging uses"
    Staging sets `CREDS_SOURCE=env` for the database, and `AMQP_CREDS_SOURCE=aws` so the AMQP
    creds still come from `RABBITMQ_SECRET_ID`: the least-privilege `stream-engine` user, whose
    permissions are in `monitoring/rabbitmq/definitions.template.json`. Without that override the
    worker would read `RABBITMQ_USER` / `RABBITMQ_PASSWORD` from the host `.env`, which is the
    broker's `RABBITMQ_DEFAULT_USER` (the administrator). `scripts/ci/check-amqp-least-priv.py`
    (PR Validation) fails a PR that brings that back, and checks the user's permission regexes
    cover every exchange and queue the worker uses. `compose.production.yml` does not set
    `CREDS_SOURCE` and uses the Secrets Manager user for both.

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
| `AVAILABILITY_EXCLUSIONS_ENABLED` | `true` | — | leave out-of-service and no-data time out of availability |
| `COUNTERS_ONLY_AVAILABILITY_ENABLED` | `false` | `true` | count-based availability for listed machines |
| `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS` | empty | `68,69,70,71,72` (CPACK L6 members) | |
| `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` | 300 | 300 | session gap for all count-based availability |
| `COUNTERS_ONLY_LINE_LEAD_ENABLED` | `false` | `true` | line-lead pass |
| `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` | empty | `3,5,2000003` | unioned at boot with descriptor-selected enterprises |
| `OEE_AVAIL_FLOOR_ENABLED` | `false` | `true` | raise running time to count-derived active time (listed machines) |
| `OEE_CANONICAL_APQ_ENABLED` | `false` | `true` | store `oee = oee_a·oee_p·oee_q` at every grain |
| `STRANDED_FLAG_SWEEP_ENABLED` | `true` | — | hourly stranded-flag sweep |
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
| `CPAC_EVENT_ENTERPRISES` | empty | — (host `.env`; CPACK = 3 per compose comment) | shadow instance scope |
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
| `PO_RECOMPUTE_SWEEP_HOURS` | 24 | — | closed-row sweep period; 0 = off |
| `PO_AVAILABILITY_ENABLED` | `false` | `true` | PO available/planned time |
| `UNS_REFRESH_ENABLED` / `UNS_INTERVAL_MINUTES` | `false` / 5 | `true` / — | |
| `UNS_CURRENT_METRICS_ENABLED` / `…_INTERVAL_MINUTES` | `false` / 1 | `true` / — | |
| `SHIFT06_REPORT_ENABLED`, `SHIFT06_INTERVAL_MINUTES`, `SHIFT06_CUSTOMER_ID` | `false`, 15, 6 | `true`, 15, — | |
| `SAP13_REPORT_ENABLED`, `SAP13_INTERVAL_MINUTES`, `SAP13_CUSTOMER_ID`, `SAP13_REASONS_FROM_DIM` | `false`, 15, 13, `false` | `true`, 15, —, `false` | |
| `SYNC06_REPORT_ENABLED`, `SYNC06_INTERVAL_MINUTES`, `SYNC06_ENTERPRISE_ID` | `false`, 15, 6 | `true`, —, — | |
| `BOXES13_REPORT_ENABLED`, `BOXES13_INTERVAL_MINUTES` | `false`, 5 | `true`, — | |
| `BOXES_BRIDGE_ENABLED` | `false` | `true` | |

**`compose.production.yml`** (not promoted) differs: Secrets Manager credentials
(`packiot/production/*`), no analytics pool (everything on the `public` route), `CONSUME_LANES=2`, no
allowlist, line-lead for enterprise 3 only, counters-only availability off, no availability floor or
canonical A·P·Q, and no closer, CPAC, Bronze, report or box jobs (the hour backfill, DQ scan, Silver
clamp, exclusions and stranded sweep run on their code defaults).

## Data & invariants

- **Silver is idempotent.** Every ingest write is an upsert keyed `(ts_value, id_equipment)` (or
  `(id_equipment, ts_event)` for events), so retries and duplicate deliveries do not change Silver.
  Bronze is append-only and does record duplicates.
- **Unregistered topics are skipped, never retried**; they are counted per tenant. A switched
  tenant's unstamped bindable metric is quarantined, never guessed.
- **Tenant fence**: the equipment id comes from the resolver for the message's own topic (or the
  decoder's stamp for switched tenants); the tenant is the topic's first segment.
- **Physical bounds**: running/stopped/downtime ≤ bucket length at the hour, shift, line-lead and
  PO grains; day/week/month sums are stored raw (no day-length cap since 2026-10-13 — a day above
  its DST-aware length is reported by invariant `K7_day_time_gt_day_length`); `0 ≤ oee_a ≤ 1`; `oee`, `oee_p`, `oee_q` ≥ 0 with no upper
  cap; no clamp between `net` and `gross` (#1482). Enforced by the SQL, the Silver clamp and the
  `*_oee_bounds` CHECK constraints.
- **Single writer per cell**: line-lead writes tp=3 rows of its scope; counters-only availability
  writes the listed machines; the exclusions step only reduces `available_time`; the closer only
  sets `ts_end`; the CPAC deriver never touches operator-edited events.
- **Canonical OEE** (`OEE_CANONICAL_APQ_ENABLED`): after each pass, `oee = oee_a × oee_p × oee_q`.
- **Flagged ⊆ computable**: re-flag scopes match eligibility scopes; the stranded sweep clears the
  rest with a WARN.
- **Lineage**: hour, shift, day, week and month rows carry `computed_at` and `source_watermark`.

## Observability

| Metric | Meaning |
|---|---|
| `oeecloud_worker_amqp_deliveries_total{routing_key,result}` | `acked`, `nacked_retry`, `exhausted_failed` |
| `oeecloud_worker_handler_duration_seconds{routing_key}` | time per delivery |
| `oeecloud_worker_batch_writes_total{dest,tenant,result}` | statements per destination and tenant (`ok`, `error`, `empty_batch`) |
| `oeecloud_worker_job_ticks_total{job,outcome}` | every scheduled job |
| `packml_unresolved_topic_total{tenant}` | metrics skipped for an unregistered topic |
| `oeecloud_worker_birthbind_verify_total`, `oeecloud_worker_birthbound_resolve_total{tenant,result}` | ADR-0061 verification and switched-tenant outcomes (`bound`, `quarantined`) |
| `oeecloud_worker_amqp_{delivered,acked,nacked_retry,published_to_failed}_total`, `oeecloud_worker_po_control_ops_total` | cumulative counters |

`/health` (port 9101) returns the consumer snapshot plus writer stats (`po_parameter`, `sparkplug`
counters such as `sparkplug_double_encoded_dropped`). `healthy` means the AMQP connection is up.

Alerts in `monitoring/prometheus/rules.yml`: `EngineJobErrorStreak` (> 2 failed ticks of one job in
15 min), `StreamEngineJobStalled` (no successful tick of a frequent job in 15 min), `EngineStalled`
(no job ticks at all), `IngestSilent`, `WritePathDry`, `BatchWriteErrors`, `ClientIngestStopped`,
`PackmlUnroutableTopic`, `BirthBindVerifyMismatch`, `BirthBoundQuarantine`. The in-DB data
invariants (`ops.job_data_invariants`, #1543) page through `DataInvariantCritical` /
`DataInvariantWarn`; see [Timescale jobs](timescale-jobs-and-retention.md#all-jobs).

Log lines to grep: `runtime-rollup-shift draining backlog`, `job tick TIMED OUT`,
`hour-backfill drained a batch`, `silver invariant clamp CHANGED gold rows`,
`stranded recalc flags cleared`, `equipment_values: topic not registered, skipping (sampled 1/32)`,
`increment sanity clamp REJECTED`, `stale-open events closed`, `tenant allowlist applied`,
`message exceeded retry limit, sent to failed queue`.

Quick SQL checks (analytics DB):

```sql
-- live shift row computed recently? (the row where ts_value <= now() < ts_end)
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
| Open stops that never close (to 2026-10-09) | 46 Bispharma machines in an open stop for days while producing | PLC-link arms minted no-data/stop rows for net-only non-lead machines the deriver never sees produce | #1663: link events only for equipment seen producing in 7 days |
| Double retries (to 2026-10-06) | each nacked tenant message came back twice; duplicate failures | shared retry/failed queues bound with `#` also matched tenant keys | #1567: exact `sparkplug.data` binding, then unbind `#` |
| Unbacked increments (to 2026-10-01) | e.g. 263,098 written while the counter moved 4 | stale decoder baseline after a long gap passed both spike and rate checks | #1544 counter-movement catch; decoder Calc baselines now durable (#1671/#1672) |
| Shift boundary hours (to 2026-10-01) | CPACK line shifts off 10.2% on average, day totals right | buckets starting inside the shift were taken whole | #1545: overlap + 1-min clip at the edges |
| Stranded flags (found 2026-10-01) | backlogs that never drain; repairs silently skipped | flags outside every pass's reach | #1541 hourly sweep with WARN |
| Re-flag of 30-day-old shifts (2026-10-01, self-inflicted) | shift rollup stalled for every tenant ~22 min | oldest-first batch of expensive old shifts timed out each tick | cleared the flags; rule: re-flag gold ≤ 7 days only |
| PO compute flag race (to 2026-09-30) | repaired POs with NULL counters and `recalc_needed = false` | phases were separate statements, each re-reading the flag | #1520: one REPEATABLE READ transaction |
| Day-length cap (to 2026-10-13) | a day's time columns silently clipped to its length, hiding mis-attributed hour buckets; `oee_p` biased low on those days | `LEAST(Σ hours, day length)` in the day rollup (task #59) | store raw like P and Q; invariant K7 reports days above their length |
| Clamps distorting data (to 2026-09-29) | line gross +1–2%, scrap +13–21% per month; P/Q capped at 1 | `net ≤ gross` clamps and upper caps in Gold | #1482: store raw; only availability capped |
| Phantom RUNNING rows (to 2026-09-29) | count-silence deriver minted a running row every tick | uncorrected re-mint | #1486 + cleanup migration |
| Live shift starved (to 2026-09-28) | current-shift OEE 0 all day; daily totals correct | oldest-first `LIMIT 75` against a 127-row recurring re-flag set | #1467 fair order (`computed_at NULLS FIRST`) |
| Line-lead planned downtime ignored (~08-31 → 09-28) | CPACK line OEE 10–50% below legacy | line-lead hard-coded `planned_downtime = 0` | #1470 (live), #1473 (backfill) |
| Closer truncation (to 09-28) | zero-length or overlapping stops | `ts_end IS NULL` guard froze early closes | #1471 rebind by successor |
| Shift tick over deadline (2026-09-21 → 09-22) | Mission Control all zero platform-wide | shift line-lead took ~205 s of a 300 s deadline; the shift transaction rolled back every tick | `ROLLUP_SHIFT_LIMIT` 300 → 75 (#1380); line-lead CTEs `MATERIALIZED` (09-24, 104 s → 5–8 s) |
| Backfill over deadline (2026-09-24) | `hour-backfill line-lead: timeout` every tick | 200 line hours per tick | `ROLLUP_BACKFILL_LIMIT=50` |
| Hour reflag deadlock (2026-09-24) | `40P01` 1–2×/h | lock-order inversion between live cascade and backfill | `FOR UPDATE SKIP LOCKED` in the live path |
| Idle-in-transaction connection (2026-09-25) | shift ticks blocked for 15 min | a stream-engine connection held locks after a job deadline | terminated manually; root cause not found in code |
| Stale opens blanket availability (2026-08-24) | idle lines at ~100% availability | closer failed every tick on the compressed-chunk decompression limit (`53400`) | `SET LOCAL … max_tuples_decompressed_per_dml_transaction = 0` |
| Frozen cagg watermark (2026-09-07) | CPACK OEE stale since Sept 1; 300 s timeouts | continuous aggregates had no refresh policy | refresh + add policies (see [Timescale jobs](timescale-jobs-and-retention.md)) |
| Machine hour phantom backlog (2026-09-10) | 6 276 `recalc_needed` machine hours never draining | re-flag included `tp_equipment = 1` | re-flag scoped to `tp_equipment > 1` |
| Scope mismatch mint vs deriver (2026-07-09) | week `running_time` 4.95e9, int overflow | per-sample open events minted for `status_type != 4` | mint gated on `status_type = 4` |
| Poison storm (2026-07-12) | worker flooded by nack-retry | non-numeric Incoplast value retried forever | non-numeric values skipped |

## Operating it

- **Deploy / restart**: normal staging deploy (the identity sentinel runs after it). A restart loses
  the clamp's last-seen timestamps (totalizers are re-seeded from the DB) and the resolver caches,
  and reloads the OEE profile. Job first ticks are staggered over 45 s.
- **Onboard a tenant**: active `packml_register` rows + add the lowercased Sparkplug group to
  `WORKER_TENANT_ALLOWLIST`; if counters-only and line-metered, add the enterprise to
  `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` (or set it in the client's OEE profile) and set
  `lead_machine` / `gross_machine` / `net_machine` on the lines; if it gets CPAC-derived events, add
  it to both the CPAC list and `EVENTS_CLOSE_STALE_ENTERPRISES`. See
  `services/stream-engine/docs/onboarding-new-tenant.md` and
  [onboarding a client](../../build/operate/onboarding-a-client.md).
- **Recompute history**: re-flag rows (gold ≤ 7 days) and let the jobs drain them; older history is
  rendered from the engine's own passes with `cmd/recompute-render`. Rules are in
  [rollup internals — recomputing history](stream-engine-rollup-internals.md#recomputing-history-safely).
- **Safe**: toggling flag-gated passes by env + recreate; lowering batch limits. **Unsafe**: running
  a second replica without SAC queues (two consumers per tenant queue break ordering); editing grain
  rows by hand while a tick runs (ad-hoc SQL takes no advisory lock); mass re-flagging old rows;
  enabling the CPAC live deriver for a tenant that already has another event writer (double events).
- **Parity tool**: `cmd/port-parity` and `scripts/parity-check.sql` compare the Go SQL with the legacy
  engine.

## Tests

- Unit: `cd services/stream-engine && go test ./...` (CI: `go-services.yml`, `-race`).
- Golden fixtures against a real Postgres:
  `DATABASE_URL=postgres://… go test -tags golden -run Golden ./internal/rollup/ ./internal/events/ ./internal/pocontrol/`
  (CI job `golden-fixtures`, `postgres:15`). Covers shift fairness, line-lead (incl. lead-silent
  fallback and net machine), counters-avail, changeover, availability exclusions, PO runtime, grain
  cascade, stranded sweep, Silver clamp, unmetered, hour deadlock and the closer.
  `internal/writers/bronze_raw_golden_test.go` also has the `golden` tag but is not in the CI job.
- Integration tests skip unless their URL is set: `AMQP_TEST_URL` (topology, including the #1567
  double-retry case) and `TEST_DATABASE_URL` (CPAC deriver).

## Source map

| Path | What's there |
|---|---|
| `services/stream-engine/cmd/oeecloud-worker/main.go` | wiring of every loop and flag |
| `services/stream-engine/cmd/recompute-render/`, `internal/rollup/history.go` | history-recompute SQL rendered from the engine's passes |
| `services/stream-engine/internal/config/config.go` | env variables and defaults |
| `services/stream-engine/internal/secrets/secrets.go` | Secrets Manager / `CREDS_SOURCE=env` |
| `services/stream-engine/internal/amqp/` | topology, consumer, lanes, retry |
| `services/stream-engine/internal/handlers/sparkplug.go` | ingest handler, routing by `source_type` |
| `services/stream-engine/internal/writers/` | Silver/Bronze SQL, increment clamp, totalizer seed |
| `services/stream-engine/internal/sparkplug/` | envelope parse, resolver, birth-bound resolution |
| `services/stream-engine/internal/shiftresolver/resolver.go` | shift column fill |
| `services/stream-engine/internal/rollup/` | grains, `line_lead.go`, `availability*.go`, `compute.go`, `recalc.go`, `dq.go`, `silver.go`, `unmetered.go`, `stranded.go`, `locks.go` |
| `services/stream-engine/internal/events/` | `deriver.go`, `cpac_deriver.go`, `closer.go` |
| `services/stream-engine/internal/pocontrol/` | PO lifecycle |
| `services/stream-engine/internal/oeeprofile/` | OEE profile from client descriptors |
| `services/stream-engine/internal/uns/`, `internal/reports/` | UNS live tables, customer report writers |
| `services/stream-engine/internal/jobs/jobs.go` | job loop |
| `services/stream-engine/docs/` | onboarding and scaling strategies (A, C, D) |
| `compose.staging.yml`, `compose.production.yml` | deployed configuration |
| `monitoring/prometheus/rules.yml` | engine and data-invariant alerts |
| `docs/adr/0014-extract-oee-math-from-database-to-app.md`, `0036-data-architecture-medallion.md`, `0037-oee-correctness-remediation.md`, `0049-oee-correctness.md`, `0061-remove-packml-from-the-cloud.md`, `0062-production-order-identity-and-alphanumeric-numbers.md` | design decisions |
