---
title: Domain model
layer: 1
owner_area: compute
last_verified: 2026-10-13
---
# Domain model: the factory, the counters and the OEE math

> **Layer 1 · Architecture.** The concepts every other page assumes: how a factory is
> modelled, what the counters mean, how time is cut, how OEE is computed, and how to compare
> numbers with legacy correctly. Up: [Architecture overview](overview.md)

## Factory hierarchy

```text
enterprise (tenant, e.g. CPACK = 3)
 └─ site (plant)
     └─ area (section)
         └─ equipment
              tp_equipment = 3  LINE     e.g. L5          ← OEE is reported per line
              tp_equipment = 2  SECTOR   (groups machines; rarely carries data)
              tp_equipment = 1  MACHINE  e.g. L5-BREYER, L5-TEXA  ← where PLC counters live
```

- Dimensions live in `core.*` (`core.enterprises`, `core.sites`, `core.areas`, `core.equipments`).
- A **line** usually has no PLC of its own. Its numbers are derived from member machines
  ("line-lead"): `lead_machine` (running time and stops; PackML parameter 30702),
  `gross_machine` (infeed), `net_machine` (outfeed), `scrap_machine`, plus per-line counter
  roles `gross_counter` / `net_counter` when a PLC labels its registers the other way round.
- **OEE, downtime and production are line concepts.** Never average OEE across machines and
  lines together; filter `tp_equipment = 3`.
- A metric is tied to an equipment through its topic: `packml_register` (a view over
  `core.topic_routing`) maps the PackML topic to `id_equipment`. ADR-0061 replaces this with
  device keys bound at Sparkplug birth (`core.device_bindings`); that switch is not live yet.

## Counters

PLCs expose PackML totalizers per machine:

| PackML counter | Role | Column (increment) |
|---|---|---|
| `ProdConsumedCount` | **gross**: units that entered | `gross_production_incr` |
| `ProdProcessedCount` | **net**: good units that left | `net_production_incr` |
| `ProdDefectiveCount` | **scrap** | `scrap_incr` |

The decoder turns each totalizer into increments. The line-lead step then reconciles each
**hourly bucket** with the identity **gross = net + scrap**, filling only a meter that is
*missing* (`services/stream-engine/internal/rollup/line_lead.go`):

| Bucket reports | Result |
|---|---|
| gross and net (scrap ignored) | both **as measured**, also when gross < net (units in transit between sensors, or an undercounting infeed: shown, not fixed; since 2026-09-29) |
| net + scrap, no gross | gross = net + scrap |
| gross + scrap, no net | net = gross − scrap |
| net only | gross = net (quality 1.0, "no scrap data") |
| gross only | net = gross |

A shift or day is the **sum of its hourly buckets**, so it equals the sum of its served hour
rows. Lines with a single meter (e.g. SLEEVE1/2, net-only) always show quality 1.0 by
construction; that is correct, not a bug. A line whose meters are report-by-exception
totalizers sets `fill_missing_meter = false`: a silent hour's units arrive in the next
report, so filling the gap would count them twice (Bispharma L90, 2026-10-01).

## Time model

- All facts are stored in UTC `timestamptz`; factories run in **America/Sao_Paulo (BRT)**.
- **Shifts** are defined per area (site as fallback) in `core.shifts`; their calendar lives in
  `core.shift_hours`, where `begin_time`/`end_time` are **seconds from `week_begin`** (itself
  seconds from Monday 00:00, possibly negative). A CPACK day has three shifts starting
  06:30, 15:00 and 23:10 BRT (09:30, 18:00, 02:10 UTC).
- A shift that does not start on the hour takes the **overlapping part** of its boundary
  hours (since 2026-10-01); before that, the whole boundary hour went to one shift.
- **Production day** is the day a shift or hour belongs to, from the per-equipment day
  boundary (`piot_get_day_begin_by_equipment`).
- Grains: **hour** → **shift** → **day** → **week** → **month**; hour/shift/day are computed from
  facts, week/month cascade from day. There is also a per-**production-order** grain.

## Events and downtime

- `silver.equipment_events` holds state intervals per equipment: `status` **6 = running**,
  **10 = stopped**, **20 = no data** (the PLC could not be read); flags `planned_downtime`,
  `change_over`; the operator's reason (`cd_category`, `cd_subcategory`, notes).
- **An event lasts until the next event on the same equipment starts** (legacy semantics).
  `ts_end` is filled by the closer and re-bound to the successor when one arrives.
- Sources on staging: the CPAC count-silence deriver (counters-only clients; a stop = counts
  silent longer than the equipment's `stop_threshold_time`; with link health it writes
  no-data events), legacy replication (CPACK), the wide-row state deriver (Incoplast), and
  operator actions (justify, split, manual events) through `edge-api`.
- **Out-of-service windows** (`config.equipment_out_of_service`, set in csadmin) mark time the
  equipment was not meant to run; a line's window covers its machines.

## OEE

For a bucket (hour or shift) of a line, with `OEE_CANONICAL_APQ_ENABLED=true` (staging):

```text
ts_total          = elapsed wall-clock of the bucket (capped at now for the live bucket)
planned_downtime  = overlap of the line's planned events with the bucket
excluded          = (out-of-service ∪ no-data) time, minus what is already planned
available_time    = ts_total − planned_downtime − excluded      (never below running_time)
running_time      = time the lead machine was producing (count sessions with an idle
                    timeout, default 300 s; events for state-signal equipment)
ideal_speed       = units/min (PackML 30701 / equipment production_speed)

oee_a = running_time / available_time                 Availability, bounded to [0,1]
oee_p = gross / (ideal_speed × running_time / 60)     Performance, ≥ 0, NOT capped at 1
oee_q = net / gross                                   Quality, ≥ 0, NOT capped at 1
oee   = oee_a × oee_p × oee_q                         exactly, at every grain
```

Source: the reconcile passes in `services/stream-engine/internal/rollup/availability.go`
(hour, shift) and `day.go` / `grains.go` (day, week, month).

**Store what was measured (2026-09-29).** Performance above 1 means the configured ideal speed
is too low; hourly quality above 1 means units in transit. The data keeps both and the UI
decides how to show them. The silver invariant pass (`rollup/silver.go`) now only enforces:
availability in [0,1], no negative factor, no negative count or duration (scrap excepted: it
is signed). Every value it changes is recorded as an `INVARIANT_CLAMPED_*` row in
`silver.data_quality_event`; net > gross is detected (`NET_GT_GROSS`) but not changed.

**Day, week and month are plain sums** of the hour (day) or day (week, month) rows, times
included: since 2026-10-13 the day no longer caps its time columns at the production-day length.
Availability is recomputed from the summed times and stays capped at 1. A day whose times exceed
its own length is a data-quality signal (hour buckets attributed to the wrong day, or time counted
twice), reported by the data invariant `K7_day_time_gt_day_length`.

**Excluded time** (2026-10-01): out-of-service time is removed from available time *and*
from the target; no-data time is removed from available time but kept in the target, and
shown as `no_data_time` so coverage can be displayed.

## Production orders

- `core.production_orders`: the order, product, client, quantity, status
  **1 available · 2 running · 3 finished · 4 paused**, and header totals.
- **Identity (ADR-0062, steps 1–3 live on staging since 2026-10-08):** the number the client
  sees is text, `order_number`, unique per enterprise (leading zeros and letters kept); the
  internal key is `id_production_order`; `po_uuid` is a UUIDv7 handle. The old integer
  `id_order` still exists until step 4.
- `gold.production_orders_runtime`: one row per run window of an order on an equipment
  (`runtime_timerange`, exclusive per equipment). Header totals are re-summed from runtime
  rows by the PO recalc job while the order is flagged.
- PackML parameters **30800–30899** drive PO control from the PLC side.

## Comparing with legacy

Legacy is the oracle, but not every legacy table is trustworthy:

| Legacy data | Trust | Why |
|---|---|---|
| Raw meters (`equipment_values` increments) | ✅ | direct from the PLC |
| Hourly rows (`equipment_runtime_1hour`) | ✅ | the grain both systems compute the same way |
| Shift rows (`equipment_runtime_shift`) | ⚠️ | legacy's shift grain is lossy: it undercounts legacy's own hourly rows by several percent |
| Line rows during odd instrumentation (e.g. meter bypassed) | ⚠️ | can disagree with the line's own meter |
| Long planned stops in hourly rows | ⚠️ | legacy can miss a stop that was open when the hour was computed |

Rules: compare **machines at raw-meter grain and lines at hourly grain**; group both sides the
same way (production day in BRT); check the *current* bucket against `now()` before calling a
stall; and check that both systems use the same rated speed for the line before comparing
Performance or OEE. An hourly legacy-oracle check runs next to the in-database data
invariants; see [Analytics DB](../subsystems/analytics-db.md).
