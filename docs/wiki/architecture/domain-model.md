---
title: Domain model
layer: 1
owner_area: compute
last_verified: 2026-09-28
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
  ("line-lead"): `lead_machine` (availability and events; PackML parameter 30702),
  `gross_machine` (infeed), `net_machine` (outfeed), `scrap_machine`, plus per-line counter
  roles `gross_counter` / `net_counter` when a PLC labels its registers the other way round.
- **OEE, downtime and production are line concepts.** Never average OEE across machines and
  lines together; filter `tp_equipment = 3`.

## Counters

PLCs expose PackML totalizers per machine:

| PackML counter | Role | Column (increment) |
|---|---|---|
| `ProdConsumedCount` | **gross**: units that entered | `gross_production_incr` |
| `ProdProcessedCount` | **net**: good units that left | `net_production_incr` |
| `ProdDefectiveCount` | **scrap** | `scrap_incr` |

The decoder turns each totalizer into increments. The line-lead step then reconciles each
hourly bucket with the identity **gross = net + scrap**, filling whichever counter is missing:

| Bucket reports | Result |
|---|---|
| gross ≥ net (and maybe scrap) | take both as reported |
| **gross < net** | the gross meter undercounts → **gross = net + scrap**, net kept (since 2026-09-28) |
| net + scrap, no gross | gross = net + scrap |
| gross + scrap, no net | net = gross − scrap |
| net only (no gross meter, no scrap meter) | **gross = net** (quality 1.0 — "no scrap data") |
| gross only | net = gross |

Lines with a single meter (e.g. SLEEVE1/2 net-only) therefore always show quality 1.0 by
construction; that is correct, not a bug.

## Time model

- All facts are stored in UTC `timestamptz`; factories run in **America/Sao_Paulo (BRT)**.
- **Shifts** are defined per area (site as fallback) in `core.shifts`; their calendar lives in
  `shift_hours`, where `begin_time`/`end_time` are **seconds from `week_begin`** (which is
  itself seconds from Monday 00:00 and may be negative). A CPACK day has three shifts starting
  06:30, 15:00 and 23:10 BRT (09:30, 18:00, 02:10 UTC).
- **Production day** (`ts_value_production`) is the day a shift or hour belongs to, from the
  per-equipment day boundary (`piot_get_day_begin_by_equipment`); DST-safe.
- Grains: **hour** → **shift** → **day** → **week** → **month**; hour/shift/day are computed from
  facts, week/month cascade from day. There is also a per-**production-order** grain.

## Events and downtime

- `silver.equipment_events` holds state intervals per equipment: `status` **6 = running**,
  **10 = stopped**; flags `planned_downtime`, `change_over`; the operator's reason
  (`cd_category`, `cd_subcategory`, notes).
- **An event lasts until the next event on the same equipment starts** (legacy semantics).
  `ts_end` is filled by the closer and re-bound to the successor when one arrives.
- Sources: the CPAC count-silence deriver (counters-only clients; a stop = counts silent
  longer than the equipment's stop threshold), legacy replication (CPACK), and operator
  actions (justify, split, manual events) through `edge-api`.

## OEE

For a bucket (hour or shift) of a line:

```text
ts_total          = elapsed wall-clock of the bucket (capped at now for the live bucket)
planned_downtime  = overlap of the line's planned events with the bucket
available_time    = ts_total − planned_downtime              (planned production time)
running_time      = time the lead machine was producing (count sessions with an idle
                    timeout, default 300 s) — capped at available_time
ideal_production  = available_time/60 × ideal_speed           (units/min, PackML 30701)

oee   = net / ideal_production                                 clamped to [0,1]
oee_a = running_time / available_time                          Availability
oee_q = net / gross                                            Quality
oee_p = oee / (oee_a × oee_q)                                  Performance (closes the identity)
```

Invariants enforced by the silver clamp layer: every factor in [0,1], net ≤ gross,
no negative counts or durations; any clamp that changes a value records an
`INVARIANT_CLAMPED_*` data-quality event (`silver.data_quality_event`).

## Production orders

- `core.production_orders`: the order (`id_order` shown as "OP"), product, client, quantity,
  status **1 available · 2 running · 3 finished · 4 paused**, and header totals.
- `gold.production_orders_runtime`: one row per run window of an order on an equipment
  (`runtime_timerange`, exclusive per equipment). Header totals are re-summed from runtime
  rows by the recalc job while the order is flagged.
- PackML parameters **30800–30899** drive PO control from the PLC side.

## Comparing with legacy

Legacy is the oracle, but not every legacy table is trustworthy:

| Legacy data | Trust | Why |
|---|---|---|
| Raw meters (`equipment_values` increments) | ✅ | direct from the PLC; analytics matches within ~0.5% |
| Hourly rows (`equipment_runtime_1hour`) | ✅ | matches analytics hourly within ±0.2% |
| Shift rows (`equipment_runtime_shift`) | ⚠️ | undercount legacy's own hourly by 4–10% |
| Line rows during odd instrumentation (e.g. meter bypassed) | ⚠️ | seen at 2× the line's own meter |
| Long planned stops in hourly rows | ⚠️ | legacy can miss a stop that was open when the hour was computed |

Rules: compare **machines at raw-meter grain and lines at hourly grain**; group both sides the
same way (production day in BRT); check the *current* bucket against `now()` before calling a
stall. Known intentional differences: rated speed of L4 (165 vs 147) and L6 (152 vs 147) is
configured differently in the two systems.
