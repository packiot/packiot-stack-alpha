---
title: stream-engine rollup internals
layer: 3
owner_area: compute
last_verified: 2026-09-28
---
# stream-engine rollup internals

> **Layer 3 · Component (supplement)** — statement-by-statement walkthrough of the OEE grain
> rollups (`RunHour`, `RunShift`, `RunDay`, `RunHourBackfill` and the passes after them): which
> tables each step reads and writes, the time windows, the invariants, and how to recompute history
> safely. For engineers changing rollup SQL or repairing past OEE.
> Up: [stream-engine](stream-engine.md)

## Responsibility

The `runtime-rollup` and `runtime-rollup-hour-backfill` jobs own every value in the gold OEE grain
tables. Each run recomputes rows flagged `recalc_needed = true` from Silver facts, continuous
aggregates and events. Nothing else writes these columns (except operator-set targets, protected
by `target_customized`).

## At a glance

| Grain | Table (staging schema `gold`) | Who is computed | Source | Eligibility window | Batch |
|---|---|---|---|---|---|
| hour | `equipment_oee_hourly` | `tp_equipment > 1` | `silver.equipment_categorical_1hour`, `_1min`, `silver.equipment_events` | `[now − 65 min, now]` (live), `[now − 10 d, now − 65 min)` (backfill) | all (live), `ROLLUP_BACKFILL_LIMIT` (backfill) |
| day | `equipment_oee_daily` | `tp_equipment > 1` | `equipment_oee_hourly` | 1 month, up to the next production day | all |
| shift | `equipment_oee_shift` | `tp_equipment > 1`, plus `tp_equipment = 1` of `ROLLUP_MACHINE_LEVEL_ENTERPRISES` | `_1hour` cagg, events | 30 days | `ROLLUP_SHIFT_LIMIT` |
| week / month | `equipment_oee_weekly` / `_monthly` | `tp_equipment > 1` | `equipment_oee_daily` | 1 year | all |
| area day / shift | `area_oee_daily` / `area_oee_shift` | areas not excluded | lines (`tp_equipment = 3`) of the area | 1 month | all |
| site shift | `site_oee_shift` | all sites | `area_oee_shift` | 1 month | all |

Tables live in the analytics DB; the column definitions are in
[analytics DB schemas](analytics-db-schemas.md). In the SQL, `%[4]s` is the Gold schema, `%[3]s`
Silver, `%[2]s` the reference schema (`core`), `%[1]s` the event schema (`silver`); see `fmtRD` in
`internal/rollup/hour.go`.

## Inputs & outputs

| Reads | Written by the rollup |
|---|---|
| `silver.equipment_categorical_1hour` (gross/net/scrap increments, `ideal_production_speed`, speed sums, `id_shift`, `ts_value_production`) | `gold.equipment_oee_*`: `gross`, `net`, `scrap`, `speed`, `ideal_speed`, `available_time`, `running_time`, `stopped_time`, `planned_downtime`, `downtime`, `changeover_time`, `ideal_production`, `oee`, `oee_a`, `oee_p`, `oee_q`, `target`, `proportional_target`, `cd_shift`, `recalc_needed`, `computed_at`, `source_watermark` |
| `silver.equipment_categorical_1min` (per-minute increments) | `gold.area_oee_*`, `gold.site_oee_shift` (same columns, summed) |
| `silver.equipment_values` (last non-null `ideal_production_speed`) | `silver.data_quality_event` (DQ scan, clamp) |
| `silver.equipment_events` (`status`, `planned_downtime`, `change_over`, `ts_event`, `ts_end`) | |
| `core.equipments` (`tp_equipment`, `production_speed`, `lead_machine`, `gross_machine`, `net_machine`, `scrap_machine`, `gross_counter`, `net_counter`, `id_area`, `id_enterprise`) | |
| `core.shifts`, `config.production_targets`, DB functions `piot_get_day_begin_by_equipment`, `piot_get_shift_hour_begin_by_equipment` | |

## Internal design

### The flag model

- A grain row exists before its time comes: `runtime-provision` pre-creates future hour, day, shift,
  week and month rows (`piot_create_*_oee_*`, 30-day horizon).
- Rows are **flagged** by the jobs themselves: each pass re-flags a recent band every tick
  (hour: `[date_trunc('hour', now − 2 h), now]`; shift: `[now − 12 h, now + 18 h)`; day: the current
  production day; week/month: the current bucket). Lower grains also flag higher ones (hour → day,
  shift → area shift, day → week and month, equipment day → area day, area day → site day).
- Late data therefore only reaches a grain if its row is still in a re-flag band, or if someone
  re-flags it (see [recomputing history](#recomputing-history-safely)).
- Every pass runs in one transaction per destination. If any statement fails or the 5-minute tick
  deadline hits, the whole pass rolls back and nothing is committed.

### RunHour (live)

Transaction on the analytics pool; first `pg_try_advisory_xact_lock('<dest>:runtime')` — if
provisioning holds it, commit and skip.

| # | Step | Reads | Writes / effect |
|---|---|---|---|
| 1 | `eligible` | `equipment_oee_hourly`, `equipments` | temp table `hour_elig`: flagged rows in `[now − 65 min, now]`, `tp_equipment > 1`, not excluded |
| 2 | `values` | `_1hour` cagg (same bucket) | `gross`, `net`, `scrap = gross − net`; missing buckets → 0; **keeps** `recalc_needed = true` |
| 3 | `cascade-day` | `piot_get_day_begin_by_equipment` | flags the equipment's day row (`FOR UPDATE SKIP LOCKED`, only rows not already flagged) |
| 4 | `speed` | `_1min` cagg; LOCF of `equipment_values.ideal_production_speed`; `equipments.production_speed` | `speed` = avg per-minute speed; `ideal_speed` = avg of (bucket ideal, else last known, else `production_speed`); empty hour → 0 |
| 5 | `events` | `equipment_events` of the last 10 days, `_1hour` (last data) | only for rows that overlap an event: time in state, `available_time = total − planned`, `ideal_production = available/60 × ideal_speed`, `oee = net/ideal_production`, `oee_a`, `oee_q`; clears `recalc_needed`. Guard `ts_value ≥ now − 6 h` |
| 6 | `counters-avail` (if engaged) | `_1min` | opted-in equipment still flagged after step 5 (no events): count-session availability |
| 7 | `line-lead` (if engaged) | `_1hour`, `_1min`, line's events | full row for `tp_equipment = 3` lines of listed enterprises (see [line-lead](stream-engine.md#line-lead)) |
| 8 | `avail-floor` (if engaged) | `_1min` | `running_time = max(running_time, count-active time)`, capped at `available_time` |
| 9 | `oee-reconcile` (canonical) or `oee-p` (legacy) | row | canonical: `oee_a = running/available`, `oee_p = gross / (ideal_speed × running/60)`, `oee_q = net/gross`, each clamped to [0,1], `oee = a·p·q`. Legacy: `oee_p = oee / (a·q)` |
| 10 | `targets` | `config.production_targets` | `proportional_target = vl_day / 24` for rows just cleared, unless `target_customized` |
| 11 | `stamp` | – | `computed_at = now()`, `source_watermark = min(bucket end, now)` |
| 12 | `reflag` | – | flag the trailing band (only `tp_equipment > 1`, `SKIP LOCKED`) |

**Event effective end** (step 5, same in shift): an event ends at its `ts_end` if set, else at the
next event of the same equipment, else — for the last event — at the equipment's last data-bearing
hour + 1 h (never after now, never before its own start). Without this, a stale open event
stretched to now and fabricated availability.

**Event-less hours.** Step 5 is an inner join: an hour with no overlapping event keeps
`recalc_needed = true` and its time columns untouched (unless step 6 or 7 handles it). It is
re-selected each tick while in the 65-minute window.

**Clamps inside the SQL**: `running_time`, `stopped_time`, `planned_downtime`, `downtime`,
`changeover_time` ≤ elapsed bucket time; OEE factors in [0,1]. They exist because overlapping
per-member events once summed to 135 M s in one hour and overflowed int4 in the day sum
(2026-07-10).

### RunHourBackfill

Separate job, own advisory key `<dest>:runtime-backfill`, own transaction.

1. `hour_elig` = oldest `ROLLUP_BACKFILL_LIMIT` flagged hour rows with
   `now − 10 days ≤ ts_value < now − 65 min`, `tp_equipment > 1`; then `CREATE INDEX` + `ANALYZE` on
   the temp table so the planner drives from it.
2. The same statements as `RunHour` steps 2, 3 (blocking variant), 4, 5, 7 (line-lead, with the
   planned-downtime predicate since #1473), 10, with every `now() − 65 minutes` and `now() − 6 hour`
   replaced by `now() − 10 days` (`widenHourWindows`). Row math is unchanged; only row selection widens.
3. `clear`: set `recalc_needed = false` on the whole batch (otherwise event-less old hours would be
   selected forever).
4. The same finalize as the live path (canonical reconcile or legacy `oee_p`), widened.

No re-flag step. The day rows it flags are recomputed by the live `RunDay` (1-month window).
The 10-day limit exists because events older than 10 days are outside the events CTE.

### RunDay

Transaction, `<dest>:runtime` try-lock.

| # | Step | What |
|---|---|---|
| 1 | `eligible` | `day_elig`: flagged day rows in the last month, before the next production-day anchor, `tp_equipment > 1`; also computes `day_len_s` = real production-day length from two consecutive `piot_get_day_begin_by_equipment` anchors (82 800 / 86 400 / 90 000 s with DST) |
| 2 | `rollup` | sum hour rows with `hr.ts_value_production = day.ts_value` (and `hr.ts_value ≥ day − 1 day`): counts, times (each time column capped at `day_len_s`), `ideal_production`, `target` (kept if customized), `proportional_target`; `oee = Σnet / Σideal_production`, `oee_a`, `oee_q`, back-solved `oee_p`; clears the flag |
| 3 | `oee-reconcile` (canonical) | factors-first: `oee_p = gross × available / (ideal_production × running)`, `oee = a·p·q` |
| 4 | `cascade-month`, `cascade-week` | flag the month and week rows |
| 5 | `stamp` | lineage columns |
| 6 | `reflag` | flag the current production day (`tp_equipment > 1`) |

A production day whose `day_begin` is not on the hour straddles 25 hour buckets; the `day_len_s` cap
stops it exceeding its real length, but the neighbouring day stays short (known limitation, task #59).

### RunShift

Transaction, `<dest>:runtime` try-lock. Returns the batch size; a full batch logs
`runtime-rollup-shift draining backlog`.

| # | Step | What |
|---|---|---|
| 1 | `eligible` | `shift_elig`: flagged shift rows in `[now − 30 d, now]`, (`tp_equipment > 1` and area not excluded) or (`tp_equipment = 1` and enterprise in `ROLLUP_MACHINE_LEVEL_ENTERPRISES`), enterprise not excluded; **`ORDER BY computed_at NULLS FIRST, ts_value` `LIMIT ROLLUP_SHIFT_LIMIT`**; then index + `ANALYZE` |
| 2 | `values` | `_1hour` buckets with the same `id_shift` and `ts_value_production`, `ts_value ≥` shift start: `gross`, `net`, `scrap`, running-only `speed`, `ideal_speed` (bucket → LOCF → `production_speed`, also when no bucket matched), `cd_shift`; **clears** the flag |
| 3 | `cascade-area` | flag `area_oee_shift` for the same `ts_value` |
| 4 | `events-bank` | temp table `shift_ev`: per row, `ts_total = min(ts_end, now) − ts_value` and overlaps of events in the last 25 days (planned, changeover, running, downtime, stopped), with the same effective-end rule as the hour |
| 5 | `events-update` | rows in `shift_ev`: time columns (capped at `ts_total`), `ideal_production`, `oee`, `oee_a`, `oee_q` |
| 6 | `counters-avail` (if engaged) | opted-in rows **not** in `shift_ev` (last 2 days): count-session availability, `oee_p` inline |
| 7 | `line-lead` (if engaged) | line rows of listed enterprises in the last 25 days: per-hour reconciled counts summed, sessionized running, planned downtime from the line's events |
| 8 | `avail-floor` (if engaged) | as in the hour |
| 9 | `oee-reconcile` or `oee-p` | whole batch (canonical) or event rows (legacy) |
| 10 | `targets` | `proportional_target = vl_day × (ts_total − ts_planned) / 86 400` — prorated by elapsed productive time, so a live shift grows toward its full target |
| 11 | `stamp` | `computed_at`, `source_watermark = min(ts_end, now)` |
| 12 | `reflag` | every tick, even with an empty batch: `[now − 12 h, now + 18 h)` for the same equipment scope |

**Why the order matters.** Re-flag keeps the recent ~30 hours permanently eligible. With oldest-first
order and a limit smaller than that recurring set, the same finished shifts were recomputed every tick
and the live shift was never reached (2026-09-22 → 09-28, fixed by #1467). `computed_at NULLS FIRST`
makes it round-robin: never-computed rows first, then whichever was computed longest ago. Re-flag does
not touch `computed_at`, so it cannot jump the queue.

**Why the limit exists.** One slow step rolls back the whole transaction. On 2026-09-22 the line-lead
step alone took ~205 s of the 300 s deadline with 63 lines at limit 300; nothing committed for hours.
The limit bounds each tick so it commits.

### RunGrains (week, month)

No transaction wrapper, no lock. For each of `week` (`vl_week`) and `month` (`vl_month`):

1. `rollup`: flagged rows of the last year, `tp_equipment > 1`: sum `equipment_oee_daily` rows whose
   `date_trunc(grain, day)` equals the bucket; 13 metrics; clamped `oee`, `oee_a` (float cast —
   these columns are `bigint`), `oee_q`; clear the flag; lineage stamp.
2. `oee-reconcile` (canonical, uses `gross × available / (ideal_production × running)`) or legacy
   `oee_p`.
3. `reflag` the current bucket.
4. `targets` from `production_targets` unless `target_customized` (enterprise must be active).

The legacy engine wrote the week's `oee_p` into the **month** table (the "amber bug"); the port writes
each grain to its own table.

### RunEntityGrains (area, site)

No lock. Area: day-flag cascade from `equipment_oee_daily` of the area's lines (`tp_equipment = 3`)
→ `area_oee_daily` rollup (sum, 1-month window) → `oee_p` → `area_oee_shift` rollup from
`equipment_oee_shift` → `oee_p` → shift tail re-flag of the current production day. Site: same, but
only the shift grain (`site_oee_shift` from `area_oee_shift`); `site_oee_daily` was dropped (#263).
Area and site hour/week/month grains were retired (#186).

### After the grains

1. `RunDQScan` — detects and records `data_quality_event` rows; changes nothing.
2. `RunSilverClamp` — `<dest>:runtime` try-lock; clamps real violators (factors to [0,1], `net` to
   `gross`, negatives to 0) and records an `INVARIANT_CLAMPED_*` event for each.
3. `RunUnmetered` — `<dest>:runtime` try-lock; sets OEE to NULL on machine rows (`tp_equipment = 1`)
   of enterprises that are not machine-metered, in the last 90 days and future buckets. Each table in
   its own savepoint so a missing table is skipped.

!!! warning "Observation: machine-scoped passes may be inert on staging"
    Hour and day only compute `tp_equipment > 1`; shift includes machines only for
    `ROLLUP_MACHINE_LEVEL_ENTERPRISES` (default `6`). Staging lists CPACK L6 member machines
    `68,69,70,71,72` (enterprise 3) in `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS`, which also drives the
    availability floor. Read from the code, those machines are never in `hour_elig` or `shift_elig`,
    so `counters-avail` and `avail-floor` select no rows, and `RunUnmetered` nulls those machines' OEE
    anyway. Not checked against live data.

## Configuration

All knobs are listed in [stream-engine › Configuration](stream-engine.md#configuration). The ones that
change rollup behaviour: `RUNTIME_ROLLUP_ENABLED`, `ROLLUP_SHIFT_LIMIT`, `ROLLUP_BACKFILL_*`,
`ROLLUP_MACHINE_LEVEL_ENTERPRISES`, `EVENTS_EXCLUDED_AREAS/ENTERPRISES`, `COUNTERS_ONLY_*`,
`OEE_AVAIL_FLOOR_ENABLED`, `OEE_CANONICAL_APQ_ENABLED`, `CHANGEOVER_AVAILABILITY_ENABLED`,
`DQ_ALARMS_ENABLED`, `SILVER_CLAMP_ENABLED`.

`CHANGEOVER_AVAILABILITY_ENABLED` changes the planned-downtime predicate at hour and shift from
`planned_downtime = true` to `planned_downtime = true AND change_over IS DISTINCT FROM true`, so
changeover counts against availability. The PO grain always uses the first form.

## Data & invariants

| Invariant | Where enforced |
|---|---|
| Time in any state ≤ bucket length | `LEAST(…, ts_total)` in hour/shift/line-lead; `day_len_s` in day |
| `0 ≤ oee, oee_a, oee_p, oee_q ≤ 1` | clamps in every formula + Silver clamp + table CHECK constraints (#663) |
| `oee = oee_a·oee_p·oee_q` | canonical reconcile at hour, shift, day, week, month (`OEE_CANONICAL_APQ_ENABLED`) |
| `net ≤ gross` | per bucket in line-lead; Silver clamp elsewhere |
| One writer per cell | line-lead vs counters-avail are per-enterprise exclusive; counters-avail only touches event-less rows |
| Flagged ⊆ computable | re-flag scopes match eligibility scopes (the 2026-09-10 machine-hour phantom backlog) |
| Targets respected | `target_customized` rows keep their `target` |

## Observability

- Freshness: `computed_at` and `source_watermark` on hour/shift/day/week/month rows.
- Backlog: `count(*) … WHERE recalc_needed` per grain within its window.
- Job health: `oeecloud_worker_job_ticks_total{job="runtime-rollup"|"runtime-rollup-hour-backfill"}`.
- Logs: `runtime-rollup-hour failed`, `runtime-rollup-shift failed`, `runtime-rollup-shift draining
  backlog`, `job tick TIMED OUT`, `hour-backfill drained a batch`, `data-quality events recorded`,
  `silver invariant clamp CHANGED gold rows`.
- In Postgres: `pg_stat_activity` for long `UPDATE gold.equipment_oee_shift`, `pg_locks` for advisory
  locks (`locktype = 'advisory'`).

## Failure modes

The incident table is on the [stream-engine](stream-engine.md#failure-modes) page. Patterns to
recognise:

| Pattern | Look at |
|---|---|
| Current shift reads 0, hourly and daily fine | shift batch starvation or rollback — the live row's `computed_at`, `draining backlog` logs |
| Everything stale at once | tick timeouts (a slow step rolls back the whole pass), provision holding `<dest>:runtime`, frozen cagg watermark |
| Old hours never change after a fix | outside the 10-day backfill horizon or not re-flagged |
| Availability ~100% on an idle line | an open event without end (closer scope, trailing-event bound) |
| Availability 0 with production | no events and not in a count-based pass (line-lead / counters-avail lists) |
| OEE > what legacy shows by a constant factor | double writers or double sources (two publishers, Phase 9 + line derivation) |

## Operating it

### Recomputing history safely

Use this after a code fix or a Silver repair.

1. **Back up** the rows you will touch (`CREATE TABLE ops._bkp_<topic>_<date> AS SELECT …`).
2. **Fix Silver first**, then refresh the continuous aggregates over the affected range
   (`CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', from, to)`, then `_1hour`).
   The grains read the caggs, not Silver. For writes into compressed chunks set
   `SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0` in that session.
3. **Re-flag, don't recompute by hand.** Set `recalc_needed = true` on the target rows and let the
   jobs drain them with the same code as the live path:

   | Grain | Drained by | Reachable history |
   |---|---|---|
   | hour | backfill (`ROLLUP_BACKFILL_LIMIT` rows every `ROLLUP_BACKFILL_INTERVAL_SECONDS`) | 10 days (event window) |
   | shift | live `RunShift` (`ROLLUP_SHIFT_LIMIT` per minute) | 30 days; line-lead part 25 days |
   | day | live `RunDay` (all flagged) | 1 month |
   | week / month | `RunGrains` | 1 year |
   | area / site | `RunEntityGrains` | 1 month |

   Hour re-flags cascade to day; day to week/month. Re-flag shift rows yourself.
4. **Re-flag in slices** (for example one day per statement, waiting for the backlog to drain). A huge
   re-flag makes shift ticks carry the old backlog; with fair ordering the live shift still gets a
   turn, but drains take longer.
5. **Only lines and sectors** (`tp_equipment > 1`) are recomputed at hour/day, plus machines of
   machine-level enterprises at shift. Flags on other machine rows never drain; don't set them.
6. **Older than the windows**: the jobs will not reach it. Options are a one-off run of the same SQL
   with widened windows (as `widenHourWindows` does) in a maintenance window, or leaving history as is.
   Hand-run SQL does not take the advisory lock; stop or pause the job (flag off + recreate) first.
7. **Verify**: compare against the legacy oracle for closed periods and the live window; check
   `oee ≈ oee_a·oee_p·oee_q`, `computed_at` updated, no new `data_quality_event` rows.

### Changing rollup SQL

- Keep the `*StatementsForParity` accessors in sync and extend the golden fixtures.
- Any new step must fit in the 5-minute tick together with all other steps. Measure with the real line
  count (`EXPLAIN (ANALYZE, BUFFERS)` on staging), and prefer `LATERAL … OFFSET 0` per line/PO and
  `MATERIALIZED` CTEs where a CTE is referenced from a join (the #259 and 2026-09-24 lessons).
- A new flag-gated pass must not write rows another pass writes.

## Tests

`DATABASE_URL=postgres://… go test -tags golden -run Golden ./internal/rollup/ ./internal/events/`
from `services/stream-engine` (CI job `golden-fixtures`). Relevant files: `golden_test.go`,
`shift_golden_test.go`, `line_lead_golden_test.go`, `counters_avail_golden_test.go`,
`changeover_golden_test.go`, `day_clamp_golden_test.go`, `hour_deadlock_golden_test.go`,
`silver_clamp_golden_test.go`, `unmetered_golden_test.go`, `inferspeed_golden_test.go`,
`backfill_test.go`.

## Source map

| Path | What's there |
|---|---|
| `services/stream-engine/internal/rollup/hour.go` | `RunHour`, `fmtRD`, hour SQL |
| `services/stream-engine/internal/rollup/backfill.go` | `RunHourBackfill`, `widenHourWindows` |
| `services/stream-engine/internal/rollup/day.go` | `RunDay` |
| `services/stream-engine/internal/rollup/shift.go` | `RunShift`, fair-order eligibility |
| `services/stream-engine/internal/rollup/grains.go` | `RunGrains`, `LoopGrains` (the tick order) |
| `services/stream-engine/internal/rollup/entity_grains.go` | area/site grains |
| `services/stream-engine/internal/rollup/line_lead.go` | line-lead SQL, planned predicate token |
| `services/stream-engine/internal/rollup/availability.go` | counters-avail, floor, canonical reconcile, `plannedDowntimeExpr` |
| `services/stream-engine/internal/rollup/oee.go` | canonical OEE formulas in Go (reference) |
| `services/stream-engine/internal/rollup/dq.go`, `silver.go`, `unmetered.go` | post-grain passes |
| `services/stream-engine/internal/rollup/provision.go`, `locks.go` | provisioning, advisory lock helper |
| `services/stream-engine/cmd/port-parity/`, `services/stream-engine/scripts/parity-check.sql` | parity tooling |
