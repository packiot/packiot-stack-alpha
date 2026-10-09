---
title: Compute
layer: 2
owner_area: compute
last_verified: 2026-09-28
---
# Compute

> **Layer 2 · Subsystem** — the scheduled jobs that turn Silver facts and events into the OEE
> numbers the product serves: hour/shift/day/week/month grains, area and site rollups, downtime
> events, production-order OEE, live UNS tables and customer reports. For anyone asking "why does
> this OEE number look like this, and when does it update?".
> Up: [Architecture overview](../architecture/overview.md)

## Purpose

OEE is Availability × Performance × Quality. Compute derives each factor from what ingestion stored:
counts from the continuous aggregates over `silver.equipment_values`, run/stop time from
`silver.equipment_events` (or, for counter-only clients, from count activity), ideal speed from the
equipment configuration, and planned stops from operator-classified events. It writes the results
into the Gold tables that read-api, Superset and the historian serve. All of it runs in one Go
process, the [stream-engine](../components/stream-engine.md), as ticker jobs. The math was ported
from the legacy PL/pgSQL engine (ADR-0014) and then corrected (ADR-0037, ADR-0049).

On staging this is the only OEE engine. Legacy production clients are still computed by the legacy
platform's database triggers and procedures.

## Boundaries

| Owns | Does not own |
|---|---|
| Every column of `gold.equipment_oee_{hourly,daily,weekly,monthly,shift}`, `gold.area_oee_{daily,shift}`, `gold.site_oee_shift` (except operator-customized targets) | Writing Silver facts ([ingestion](ingestion.md)) |
| Deriving and closing `silver.equipment_events` for configured tenants | Continuous aggregate refresh, compression, retention ([analytics DB](analytics-db.md)) |
| `gold.production_orders_runtime` metrics and `core.production_orders` OEE columns | PO creation from the UI (edge-api) and PO replication from legacy ([legacy bridge](legacy-bridge.md)) |
| UNS live tables (`silver.equipment_live_*`, `silver.area_live_*`) | Serving functions and dashboards ([serving APIs](serving-apis.md)) |
| `data_quality_event` detection and the Gold invariant clamp | Long-range history ([historian](historian.md)) |
| Customer report pools (`customer_reports.*` for enterprises 6 and 13, boxes) | |
| Provisional ideal-speed inference (off) | Setting `production_speed`, targets, lead machines (onboarding) |

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| stream-engine — rollup jobs | hour, day, shift, week, month, area, site grains; backfill; provision | Go, container `stream-engine` | [stream-engine](../components/stream-engine.md), [rollup internals](../components/stream-engine-rollup-internals.md) |
| stream-engine — event jobs | status-4 deriver, CPAC count-silence deriver, stale-open closer | same process | [stream-engine › Events](../components/stream-engine.md#events) |
| stream-engine — PO jobs | PO runtime compute and headline recalc; PO lifecycle on the ingest path | same process | [stream-engine › Production orders](../components/stream-engine.md#production-orders) |
| stream-engine — UNS and reports | live tables, customer report writers | same process | [stream-engine](../components/stream-engine.md#scheduled-jobs) |
| TimescaleDB continuous aggregates (input) | `silver.equipment_categorical_1min/_1hour`, `ca_discrete_changes_1s` | analytics DB | [Timescale jobs & retention](../components/timescale-jobs-and-retention.md) |
| DB helper functions (input) | `piot_get_day_begin_by_equipment`, `piot_get_shift_hour_begin_by_equipment`, `piot_create_*_oee_*` | analytics DB | [analytics DB schemas](../components/analytics-db-schemas.md) |

## How it works

```text
 silver.equipment_values ──(caggs)──▶ equipment_categorical_1min / _1hour
 silver.equipment_events ─────────────────────────────┐
                                                      ▼
  every 1 min: runtime-rollup ─────────────────────────────────────────────────────────────┐
  │ hour (lines, last 65 min) ─▶ day (sums hours) ─▶ shift (≤ ROLLUP_SHIFT_LIMIT rows) ─▶     │
  │ week/month (sum days) ─▶ area/site (sum lines) ─▶ DQ scan ─▶ Silver clamp ─▶ unmetered    │
  └────────────────────────────────────────────────────────────────▶ gold.equipment_oee_*   │
  every 7 s: hour backfill (flagged hours 65 min – 10 days old)                              │
  every 6 h: provision future grain rows (holds the runtime lock)                            │
  every 1 min: events deriver / CPAC deriver / closer ──▶ silver.equipment_events            │
  every 1 min: PO compute ─▶ PO recalc ─▶ equipment_live_job                                 │
  every 1–5 min: UNS live tables;  every 15 min: customer reports                            │
```

**The recalc flag.** Every grain row has `recalc_needed`. The jobs re-flag a recent band on every tick
(hours of the last ~2–3 h, shifts in `[now − 12 h, now + 18 h)`, the current day/week/month) and
recompute flagged rows inside their window. Late data is picked up while its row is in the band; older
rows need an explicit re-flag (see [recomputing history](../components/stream-engine-rollup-internals.md#recomputing-history-safely)).

**Three ways to get availability**, chosen per enterprise or equipment:

| Mode | Used for | Running time from |
|---|---|---|
| State events | equipment with a state signal (`status_type = 4`) or with replicated/derived events | overlap of status-6 events with the bucket |
| Line-lead | counter-only, line-metered enterprises (`COUNTERS_ONLY_LINE_LEAD_ENTERPRISES`: 3, 5, 2000003 on staging) | sessions of the lead machine's productive minutes; gross/net/scrap from designated member machines |
| Counters-only fallback | listed machines with no events (`COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS`) | sessions of the machine's own productive minutes |

Planned downtime always comes from events classified `planned_downtime` (by operators or the source
system), and is removed from the availability denominator.

**Events** feed availability and the downtime screens. Who writes them depends on the tenant on staging:
CPACK (3) — replicated from legacy by [analytics-sync](../components/analytics-sync.md); Bispharma (5) — minted by the CPAC count-silence deriver;
Incoplast (4) — derived from wide-row state; `status_type = 4` equipment — the state deriver. The
closer bounds open events of 3, 4, 5 and 2000003 so an open event cannot stretch to now.

## Interfaces

| Direction | Protocol | Table / function | Producer → consumer |
|---|---|---|---|
| in | SQL | `silver.equipment_categorical_1min`, `_1hour`, `ca_discrete_changes_1s` (caggs) | TimescaleDB → stream-engine |
| in | SQL | `silver.equipment_values`, `silver.equipment_events` | ingestion, legacy-replicator, edge-api → stream-engine |
| in | SQL | `core.equipments`, `core.shifts`, `core.production_orders`, `config.production_targets`, `client_descriptors` | onboarding (csadmin, edge-api) → stream-engine |
| out | SQL | `gold.equipment_oee_*`, `gold.area_oee_*`, `gold.site_oee_shift` | stream-engine → read-api `serving.*`, Superset, historian |
| out | SQL | `silver.equipment_events` (`ts_end`, derived rows) | stream-engine → rollups, downtime screens |
| out | SQL | `gold.production_orders_runtime`, `core.production_orders` OEE columns | stream-engine → PO screens, operator app |
| out | SQL | `silver.equipment_live_*`, `silver.area_live_*` | stream-engine → Mission Control |
| out | SQL | `silver.data_quality_event` | stream-engine → DQ dashboards / alerts |
| out | SQL | `customer_reports.*` | stream-engine → customer integrations |

## Data it owns

| Data | Grain / key | Lifecycle |
|---|---|---|
| `gold.equipment_oee_hourly` | `(id_equipment, ts_value)` hour; lines and sectors only | pre-created by provision; recomputed while flagged; kept (compact) |
| `gold.equipment_oee_shift` | `(id_equipment, ts_value)` shift start, with `ts_end`, `id_shift` | recomputed ≤ 30 days back |
| `gold.equipment_oee_daily` / `_weekly` / `_monthly` | production day / week / month | recomputed ≤ 1 month / 1 year back |
| `gold.area_oee_daily`, `gold.area_oee_shift`, `gold.site_oee_shift` | area/site × bucket | summed from lines |
| `gold.production_orders_runtime` metrics | `(id_equipment, runtime_timerange)` | recomputed within `PO_RECALC_WINDOW` (1 month) |
| `silver.equipment_events` (derived rows, `ts_end`) | `(id_equipment, ts_event)` | derivers look back 25 h; closer 72 h + 60 days |
| `silver.data_quality_event` | `(id_enterprise, id_equipment, grain, bucket_ts, rule)` | upserted on each detection |
| UNS live tables | one row per equipment/area per grain | overwritten every refresh |

Every computed grain row carries `computed_at` (wall clock) and `source_watermark` (how far the input
data is visible), so freshness can be checked per row.

## Configuration that matters

| Knob | Staging | Effect |
|---|---|---|
| `RUNTIME_ROLLUP_ENABLED`, `ROLLUP_BACKFILL_ENABLED` | on | the grain jobs |
| `ROLLUP_SHIFT_LIMIT` | 75 | shift rows per tick; too high and the 5-minute tick rolls back |
| `ROLLUP_BACKFILL_LIMIT` / `_INTERVAL_SECONDS` | 50 / 7 | backfill drain rate |
| `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` | `3,5,2000003` | enterprises whose lines use line-lead |
| `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` | 300 | a gap longer than this between productive minutes counts as stopped |
| `OEE_CANONICAL_APQ_ENABLED` | on | `oee = A × P × Q` exactly at every grain |
| `ROLLUP_MACHINE_LEVEL_ENTERPRISES` | 6 (default) | enterprises whose machines get their own OEE; others show "not metered" |
| `EVENTS_CLOSE_STALE_ENTERPRISES`, `CPAC_EVENT_LIVE_ENTERPRISES` | `3,4,5,2000003`, `5` | event closing / minting per tenant |
| `PO_AVAILABILITY_ENABLED` | on | PO-grain availability and performance |
| Equipment config: `lead_machine`, `gross_machine`, `net_machine`, `scrap_machine`, `gross_counter`, `net_counter`, `production_speed`, `stop_threshold_time` | per line | which machines meter a line; ideal speed; stop threshold |

The full list with defaults is on the [stream-engine](../components/stream-engine.md#configuration) page.

## Failure modes & signals

| What breaks | How you notice | Where to look |
|---|---|---|
| A slow step makes the tick exceed 5 min → whole pass rolls back | stale Gold everywhere; `job tick TIMED OUT`; `EngineJobErrorStreak` | `pg_stat_activity`, per-step timing; lower the batch limits |
| Live shift not computed | current shift 0 while hours and days fine | the live row's `computed_at`; batch fairness (2026-09-28) |
| Provisioning holds the runtime lock | rollups skip for many minutes | `pg_locks` advisory; `runtime-provision` duration |
| Caggs not refreshing | every rollup slow, values lag | cagg watermarks and refresh jobs ([Timescale jobs](../components/timescale-jobs-and-retention.md)) |
| Open events never closed | idle lines at ~100% availability | closer scope and `EVENTS_CLOSE_STALE_ENTERPRISES` |
| No events and not in a count-based mode | availability 0 while producing | line-lead / counters lists, event writer for the tenant |
| Wrong meters for a line | net = gross, or gross < net | `lead_machine`, `gross_machine`, `net_machine`, counters on the line row |
| Out-of-range values | `silver invariant clamp CHANGED gold rows`, `data_quality_event` rows | the source (ingest spikes, config) |

## History & decisions

| When | Decision / incident |
|---|---|
| ADR-0014 | Move OEE math from DB triggers to the app ([ADR-0014](../adr/0014-extract-oee-math-from-database-to-app.md)) |
| ADR-0036 | Medallion: Gold grains, Silver invariant layer ([ADR-0036](../adr/0036-data-architecture-medallion.md)) |
| ADR-0037 / ADR-0049 | OEE correctness: clamps, canonical A·P·Q, availability floor, changeover option ([ADR-0037](../adr/0037-oee-correctness-remediation.md), [ADR-0049](../adr/0049-oee-correctness.md)) |
| 2026-07-09/10 | Per-sample events for non-state equipment overflowed running time → mint limited to `status_type = 4`; physical caps on every grain |
| 2026-08-24 | Stale open events faked availability → closer with unlimited decompression per transaction |
| 2026-09-07 | Production caggs without refresh policies froze the rollups (#196) |
| 2026-09-22 | Shift line-lead exceeded the tick deadline → `ROLLUP_SHIFT_LIMIT` 75 |
| 2026-09-24 | Line-lead CTEs materialized (104 s → 5–8 s); hour reflag deadlock fixed; open stops no longer truncated |
| 2026-09-27 | `net_machine` / counter roles for CPACK lines (#1461, #1463, #1464); PO compute per-PO lateral (#1465) |
| 2026-09-28 | Fair shift batching (#1467); planned downtime in line-lead (#1470, #1473); closer rebind (#1471); gross < net rule (#1472) |

## Go deeper

- [stream-engine](../components/stream-engine.md) — every job, interval, flag, lock and env var
- [stream-engine rollup internals](../components/stream-engine-rollup-internals.md) — SQL step by step, recomputing history
- [Analytics DB](analytics-db.md) and [analytics DB schemas](../components/analytics-db-schemas.md) — the tables compute reads and writes
- [Ingestion](ingestion.md) — where Silver comes from
