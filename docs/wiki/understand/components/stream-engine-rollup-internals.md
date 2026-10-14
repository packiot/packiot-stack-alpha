---
title: stream-engine rollup internals
layer: 3
owner_area: compute
last_verified: 2026-10-13
---
# stream-engine rollup internals

> **Layer 3 · Component (supplement)** — statement-by-statement walkthrough of the OEE grain
> rollups (`RunHour`, `RunShift`, `RunDay`, `RunHourBackfill` and the passes after them): which
> tables each step reads and writes, the time windows, the invariants, and how to recompute history
> safely. For engineers changing rollup SQL or repairing past OEE. Staging only: the new-stack
> production is not promoted.
> Up: [stream-engine](stream-engine.md) · [Compute subsystem](../subsystems/compute.md) ·
> [README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/stream-engine/README.md) ·
> [service catalog](../../reference/service-catalog.md)

## Responsibility

The `runtime-rollup` and `runtime-rollup-hour-backfill` jobs own every value in the gold OEE grain
tables. Each run recomputes rows flagged `recalc_needed = true` from Silver facts, continuous
aggregates and events. Nothing else writes these columns, except operator-set targets (protected by
`target_customized`) and the hand-run history repair described [below](#recomputing-history-safely).

## At a glance

| Grain | Table (staging schema `gold`) | Who is computed | Source | Eligibility window | Batch |
|---|---|---|---|---|---|
| hour | `equipment_oee_hourly` | `tp_equipment > 1` | `silver.equipment_categorical_1hour`, `_1min`, `silver.equipment_events` | `[now − 65 min, now]` (live), `[now − 10 d, now − 65 min)` (backfill) | all (live), `ROLLUP_BACKFILL_LIMIT` oldest first (backfill) |
| day | `equipment_oee_daily` | `tp_equipment > 1` | `equipment_oee_hourly` | 1 month, up to the next production day | all |
| shift | `equipment_oee_shift` | `tp_equipment > 1`, plus `tp_equipment = 1` of `ROLLUP_MACHINE_LEVEL_ENTERPRISES` | `_1hour` cagg, events | 30 days (line-lead and reconcile parts: 25 days) | `ROLLUP_SHIFT_LIMIT` |
| week / month | `equipment_oee_weekly` / `_monthly` | `tp_equipment > 1` | `equipment_oee_daily` | 1 year | all |
| area day / shift | `area_oee_daily` / `area_oee_shift` | areas not excluded | lines (`tp_equipment = 3`) of the area | 1 month | all |
| site shift | `site_oee_shift` | all sites | `area_oee_shift` | 1 month | all |

Tables live in the analytics DB; the column definitions are in
[analytics DB schemas](analytics-db-schemas.md). In the SQL, `%[1]s` is the event schema
(`silver`), `%[2]s` the reference schema (`core`), `%[3]s` Silver, `%[4]s` Gold; see `fmtRD` in
`internal/rollup/hour.go`.

## Inputs & outputs

| Reads | Written by the rollup |
|---|---|
| `silver.equipment_categorical_1hour` (gross/net/scrap increments, `ideal_production_speed`, speed sums, `id_shift`, `ts_value_production`) | `gold.equipment_oee_*`: `gross`, `net`, `scrap`, `speed`, `ideal_speed`, `available_time`, `running_time`, `stopped_time`, `planned_downtime`, `downtime`, `changeover_time`, `no_data_time`, `out_of_service_time`, `ideal_production`, `oee`, `oee_a`, `oee_p`, `oee_q`, `target`, `proportional_target`, `cd_shift`, `recalc_needed`, `computed_at`, `source_watermark` |
| `silver.equipment_categorical_1min` (per-minute increments) | `gold.area_oee_*`, `gold.site_oee_shift` (same columns, summed) |
| `silver.equipment_values` (last non-null `ideal_production_speed`, 7-day look-back) | `silver.data_quality_event` (DQ scan, Silver clamp) |
| `silver.equipment_events` (`status`, `planned_downtime`, `change_over`, `ts_event`, `ts_end`) | |
| `config.equipment_out_of_service` (exclusions) | |
| `core.equipments` (`tp_equipment`, `production_speed`, `lead_machine`, `gross_machine`, `net_machine`, `scrap_machine`, `gross_counter`, `net_counter`, `fill_missing_meter`, `id_parentequipment`, `id_area`, `id_enterprise`) | |
| `core.shifts`, `config.production_targets`, DB functions `piot_get_day_begin_by_equipment`, `piot_get_shift_hour_begin_by_equipment` | |

## Internal design

### The flag model

- A grain row exists before its time comes: `runtime-provision` pre-creates future hour, day, shift,
  week and month rows. Hour rows come from the engine's own `provisionHourlySQL` (`provision.go`);
  the other grains from the legacy `piot_create_*_oee_*` functions.
- An hour row's production day (`ts_value_production`) is the day that contains
  **bucket start + 59 minutes**, from `piot_get_day_begin_by_equipment`. It only matters for a day
  that starts off the hour: with `day_begin = -3000` (23:10 local) the bucket 23:00–00:00 local
  belongs to the new day, where 50 of its 60 minutes are. The label depends only on the bucket, so
  re-running provisioning never changes it. Until 2026-10-13 the legacy
  `piot_create_equipment_oee_hourly` labelled that bucket by the minute the job happened to run
  (legacy prod always ran it at minute 59, the engine at any minute), so CPACK, the twin, Incoplast,
  119 and 120 had production days with 23 or 25 hour rows. Invariant `K8_day_hour_rows_ne_day_hours`
  (`db/migrations/t-data-invariants-v11`, settled-day cutoff fixed in `-v12`) checks that every
  settled day of the last 7 has exactly day length / 3600 hour rows. "Settled" = the next production
  day has started (`piot_get_day_begin_by_equipment`), not "before today in UTC": production days end
  at ~02:10 UTC (day_begin −3000 s tenants) or ~08:00–09:00 UTC (Bispharma).
- Rows are **flagged** by the jobs themselves: each pass re-flags a recent band every tick
  (hour: `[date_trunc('hour', now − 2 h), now]`; shift: `[now − 12 h, now + 18 h)`; day: the current
  production day; week/month: the current bucket). Lower grains also flag higher ones (hour → day,
  shift → area shift, day → week and month, equipment day → area day).
- Late data therefore only reaches a grain if its row is still in a re-flag band, or if someone
  re-flags it (see [recomputing history](#recomputing-history-safely)).
- A flag no pass can reach is cleared hourly by the `stranded-flag-sweep` job, with a WARN
  (`stranded recalc flags cleared`, table + sample keys). It covers every grain: PO runtimes and
  headers past the PO window; shift past 30 days or `tp_equipment = 1` outside the machine-level
  enterprises; hour past the backfill horizon or `tp = 1`; day past 1 month or `tp = 1`; week/month
  past 1 year or `tp = 1`. Data invariant `O3_stranded_flags` counts the same rows (2-hour grace) and
  must read 0. Until 2026-10-14 the sweep had no day/week/month statement, so 525 machine day rows
  flagged by ops repair scripts stayed flagged for days with O3 green.
- `RunHour`, `RunDay`, `RunShift` and the backfill each run in one transaction. If a statement fails
  or the 5-minute tick deadline hits, that pass rolls back and commits nothing; the other passes of
  the tick still run.

### RunHour (live)

Transaction on the analytics pool; first `pg_try_advisory_xact_lock('<dest>:runtime')` — if
provisioning holds it, commit and skip.

| # | Step | Reads | Writes / effect |
|---|---|---|---|
| 1 | `eligible` | `equipment_oee_hourly`, `equipments` | temp table `hour_elig`: flagged rows in `[now − 65 min, now]`, `tp_equipment > 1`, not excluded |
| 2 | `values` | `_1hour` cagg (same bucket) | `gross`, `net`, `scrap = gross − net` (signed); missing buckets → 0; **keeps** `recalc_needed = true` |
| 3 | `cascade-day` | the hour row's `ts_value_production` (fallback: `piot_get_day_begin_by_equipment` at bucket + 59 min) | flags the day row the hour is summed into (`FOR UPDATE SKIP LOCKED`, only rows not already flagged) |
| 4 | `speed` | `_1min` cagg; LOCF of `equipment_values.ideal_production_speed` (≤ 7 days back); `equipments.production_speed` | `speed` = avg per-minute speed; `ideal_speed` = avg of (bucket ideal, else last known, else `production_speed`) |
| 5 | `events` | `equipment_events` of the last 10 days plus the event in effect at that bound; `_1hour` (last data) | only for rows that overlap an event: time in state, `available_time = total − planned`, `ideal_production = available/60 × ideal_speed`, `oee = net/ideal_production`, `oee_a`, `oee_q`; clears `recalc_needed`. Guard `ts_value ≥ now − 6 h` |
| 6 | `counters-avail` (if engaged) | `_1min` | opted-in equipment still flagged after step 5 (no events): count-session availability |
| 7 | `line-lead` (if engaged) | `_1hour`, `_1min`, line's events | full row for `tp_equipment = 3` lines in the line-lead scope (see [line-lead](stream-engine.md#line-lead)) |
| 8 | `avail-floor` (if engaged) | `_1min` | `running_time = max(running_time, count-active time)`, capped at `available_time` |
| 9 | `exclusions` (if engaged) | `config.equipment_out_of_service`, status-20 events | `available_time = max(total − planned − excluded, running)`; `no_data_time`, `out_of_service_time` |
| 10 | `oee-reconcile` (canonical) or `oee-p` (legacy) | row | canonical: `oee_a = running/available` in [0,1], `oee_p = gross / (ideal_speed × running/60)` ≥ 0, `oee_q = net/gross` ≥ 0, `oee = a·p·q`. Legacy: `oee_p = oee / (a·q)` ≥ 0 |
| 11 | `targets` | `config.production_targets` | `proportional_target = vl_day / 24` (minus out-of-service share) for rows just cleared, unless `target_customized` |
| 12 | `stamp` | – | `computed_at = now()`, `source_watermark = min(bucket end, now)` |
| 13 | `reflag` | – | flag the trailing band (only `tp_equipment > 1`, `SKIP LOCKED`) |

**Event effective end** (step 5, same in shift): an event ends at its `ts_end` if set, else at the
next event of the same equipment, else — for the last event — at the equipment's last data-bearing
hour + 1 h (never after now, never before its own start). Without this, a stale open event
stretched to now and fabricated availability.

**Event-less hours.** Step 5 is an inner join: an hour with no overlapping event keeps
`recalc_needed = true` and its time columns untouched (unless step 6 or 7 handles it). It is
re-selected each tick while in the 65-minute window.

**Bounds inside the SQL**: `running_time`, `stopped_time`, `planned_downtime`, `downtime`,
`changeover_time` ≤ elapsed bucket time (overlapping per-member events once summed to 135 M s in
one hour and overflowed int4 in the day sum, 2026-07-10). `oee_a` is bounded to [0, 1]; `oee`,
`oee_p` and `oee_q` are only floored at 0 since #1482 (2026-09-29), matching the relaxed
`*_oee_bounds` CHECK constraints (`db/migrations/t-oee-uncapped-data`).

### RunHourBackfill

Separate job, own advisory key `<dest>:runtime-backfill`, own transaction.

1. `hour_elig` = the oldest `ROLLUP_BACKFILL_LIMIT` flagged hour rows with
   `now − 10 days ≤ ts_value < now − 65 min`, `tp_equipment > 1`; then `CREATE INDEX` + `ANALYZE` on
   the temp table so the planner drives from it.
2. The same statements as `RunHour` steps 2, 3 (blocking variant), 4, 5, 7 (line-lead), 9
   (exclusions) and 11, with every `now() − 65 minutes` and `now() − 6 hour` replaced by
   `now() − 10 days` (`widenHourWindows`). Row math is unchanged; only row selection widens. Steps 6
   and 8 (counters-avail, floor) are not run.
3. `clear`: set `recalc_needed = false` on the whole batch (otherwise event-less old hours would be
   selected forever).
4. The same finalize as the live path (canonical reconcile or legacy `oee_p`), widened.

No re-flag step. The day rows it flags are recomputed by the live `RunDay` (1-month window). The
10-day limit exists because the events step reads only 10 days of events.

### RunDay

Transaction, `<dest>:runtime` try-lock.

| # | Step | What |
|---|---|---|
| 1 | `eligible` | `day_elig`: flagged day rows in the last month, before the next production-day anchor, `tp_equipment > 1` |
| 2 | `rollup` | sum hour rows with `hr.ts_value_production = day.ts_value` (and `hr.ts_value ≥ day − 1 day`): counts, times (raw sums, no day-length cap since 2026-10-13), `ideal_production`, `target` (kept if customized), `proportional_target`; `oee = Σnet / Σideal_production` (≥ 0), `oee_a` = Σrunning / Σavailable (in [0,1]), `oee_q` (≥ 0), back-solved `oee_p`; clears the flag |
| 3 | `oee-reconcile` (canonical) | factors-first: `oee_p = gross × available / (ideal_production × running)`, `oee = a·p·q` |
| 4 | `cascade-month`, `cascade-week` | flag the month and week rows |
| 5 | `stamp` | lineage columns |
| 6 | `reflag` | flag the current production day (`tp_equipment > 1`) |

**Day times are stored raw** (2026-10-13, user decision, same policy as P and Q in #1482). Until
then `available_time`, `running_time`, `stopped_time` and `downtime` were capped at the real
production-day length (`LEAST(Σ, day_len_s)`, task #59). Each hour row is still bounded by its own
bucket, so a day can only exceed its length when more hour buckets are attributed to it than it has
hours (a `day_begin` that is not on the hour) or when time is counted twice upstream. That is a
data-quality signal, not something to clip: invariant `K7_day_time_gt_day_length`
(`db/migrations/t-data-invariants-v10`) reports every settled day of the last 7 whose time columns
exceed the day's DST-aware length. The UI may cap for display. Its main cause was the hour-label bug
described under [the flag model](#the-flag-model); K8 now checks the labels directly.

### RunShift

Transaction, `<dest>:runtime` try-lock. Returns the batch size; a full batch logs
`runtime-rollup-shift draining backlog`.

| # | Step | What |
|---|---|---|
| 1 | `eligible` | `shift_elig`: flagged shift rows in `[now − 30 d, now]`, (`tp_equipment > 1` and area not excluded) or (`tp_equipment = 1` and enterprise in `ROLLUP_MACHINE_LEVEL_ENTERPRISES`), enterprise not excluded; **`ORDER BY computed_at NULLS FIRST, ts_value` `LIMIT ROLLUP_SHIFT_LIMIT`**; then index + `ANALYZE` |
| 2 | `values` | `_1hour` buckets with the same `id_shift` and `ts_value_production`, `ts_value ≥` shift start: `gross`, `net`, `scrap`, running-only `speed`, `ideal_speed` (bucket → LOCF → `production_speed`), `cd_shift`; **clears** the flag |
| 3 | `cascade-area` | flag `area_oee_shift` for the same `ts_value` |
| 4 | `events-bank` | temp table `shift_ev`: per row, `ts_total = min(ts_end, now) − ts_value` and overlaps of events in the last 25 days (planned, changeover, running, downtime, stopped), with the same effective-end rule as the hour |
| 5 | `events-update` | rows in `shift_ev`: time columns (capped at `ts_total`), `ideal_production`, `oee`, `oee_a`, `oee_q` |
| 6 | `counters-avail` (if engaged) | opted-in rows **not** in `shift_ev` (last 2 days): count-session availability, `oee_p` inline |
| 7 | `line-lead` (if engaged) | line rows in scope, last 25 days: per-hour-bucket reconciled counts summed (edge buckets read from the 1-min cagg, clipped to the shift, #1545), sessionized running with the lead-silent fallback, planned downtime from the line's events |
| 8 | `avail-floor` (if engaged) | as in the hour |
| 9 | `exclusions` (if engaged) | as in the hour, against the shift window |
| 10 | `oee-reconcile` or `oee-p` | whole batch (canonical, last 25 days) or event rows (legacy) |
| 11 | `targets` | `proportional_target = vl_day × (ts_total − ts_planned [− out of service]) / 86 400` — prorated by elapsed productive time, so a live shift grows toward its full target |
| 12 | `stamp` | `computed_at`, `source_watermark = min(ts_end, now)` |
| 13 | `reflag` | every tick, even with an empty batch: `[now − 12 h, now + 18 h)` for the same equipment scope |

**Why the order matters.** Re-flag keeps the recent ~30 hours permanently eligible. With oldest-first
order and a limit smaller than that recurring set, the same finished shifts were recomputed every tick
and the live shift was never reached (2026-09-22 → 09-28, fixed by #1467). `computed_at NULLS FIRST`
makes it round-robin: never-computed rows first, then whichever was computed longest ago. Re-flag does
not touch `computed_at`, so it cannot jump the queue. A burst of old flags still takes every slot
until it drains: re-flagging 78 shifts back to 30 days on 2026-10-01 made each tick time out on the
old rows (slow LOCF lookups on compressed chunks) and froze shift OEE for every tenant for ~22 min.

**Why the limit exists.** One slow step rolls back the whole transaction. On 2026-09-22 the line-lead
step alone took ~205 s of the 300 s deadline with 63 lines at limit 300; nothing committed for hours.
The limit bounds each tick so it commits.

### RunGrains (week, month)

No transaction wrapper, no lock. For each of `week` (`vl_week`) and `month` (`vl_month`):

1. `rollup`: flagged rows of the last year, `tp_equipment > 1`: sum `equipment_oee_daily` rows whose
   `date_trunc(grain, day)` equals the bucket; `oee` and `oee_q` floored at 0, `oee_a` in [0, 1]
   (float cast — these columns are `bigint`); clear the flag; lineage stamp.
2. `oee-reconcile` (canonical, uses `gross × available / (ideal_production × running)`) or legacy
   `oee_p`.
3. `reflag` the current bucket.
4. `targets` from `production_targets` unless `target_customized` (enterprise must be active).

The legacy engine wrote the week's `oee_p` into the **month** table (the "amber bug"); the port writes
each grain to its own table.

### RunEntityGrains (area, site)

No lock. Area: day-flag cascade from `equipment_oee_daily` of the area's lines (`tp_equipment = 3`)
→ `area_oee_daily` rollup (sum, 1-month window) → `oee_p` → `area_oee_shift` rollup from
`equipment_oee_shift` → `oee_p` → shift tail re-flag of the current production day. Site: only the
shift grain (`site_oee_shift` from `area_oee_shift`); `site_oee_daily` was dropped (#263). Area and
site hour/week/month grains were retired (#186).

The area day-flag cascade is **change-driven by `computed_at`**: an area day is re-flagged when one
of its lines' day rows was computed after it — whatever that line row's `recalc_needed` says.
`RunDay` re-flags every line's *current* production day right after computing it, so the old extra
condition "line row not flagged" never held for the running day: the area's current day stayed at
its provisioning zeros until the day closed, and `area_live_day` / front4 Home read 0 all day (fixed
2026-10-13). The running area day is now recomputed on every rollup tick.

### After the grains

1. `RunDQScan` — detects and records `data_quality_event` rows; changes nothing.
2. `RunSilverClamp` — `<dest>:runtime` try-lock; on rows a clamp would change: `oee_a` to [0, 1],
   `oee`/`oee_p`/`oee_q` floored at 0, negative counts and durations to 0 (scrap is signed and
   excluded); records an `INVARIANT_CLAMPED_*` event for each. It no longer lowers `net` to `gross`.
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
`OEE_AVAIL_FLOOR_ENABLED`, `OEE_CANONICAL_APQ_ENABLED`, `AVAILABILITY_EXCLUSIONS_ENABLED`,
`CHANGEOVER_AVAILABILITY_ENABLED`, `DQ_ALARMS_ENABLED`, `SILVER_CLAMP_ENABLED`,
`STRANDED_FLAG_SWEEP_ENABLED`, and the client descriptor's `oee_profile` (line-lead scope, read at
boot).

`CHANGEOVER_AVAILABILITY_ENABLED` changes the planned-downtime predicate at hour and shift from
`planned_downtime = true` to `planned_downtime = true AND change_over IS DISTINCT FROM true`, so
changeover counts against availability. The PO grain always uses the first form.

## Data & invariants

| Invariant | Where enforced |
|---|---|
| Time in any state ≤ bucket length | `LEAST(…, ts_total)` in hour/shift/line-lead. Day, week, month and area grains store the raw sums of their children (no cap); a day above its length is reported by invariant `K7_day_time_gt_day_length` |
| `0 ≤ oee_a ≤ 1`; `oee`, `oee_p`, `oee_q` ≥ 0, no upper cap | the formulas, the Silver clamp, and the `*_oee_bounds` CHECK constraints (`t-oee-uncapped-data`) |
| `oee = oee_a·oee_p·oee_q` | canonical reconcile at hour, shift, day, week, month (`OEE_CANONICAL_APQ_ENABLED`) |
| Measured counts are not adjusted | no `net ≤ gross` clamp; `scrap = gross − net` is signed; only a missing meter is filled (line-lead identity) |
| Excluded time is neither running nor stopped | exclusions step: `available_time ≥ running_time`, `no_data_time` / `out_of_service_time` recorded |
| One writer per cell | line-lead vs counters-avail are per-enterprise exclusive; counters-avail only touches event-less rows; exclusions only reduce `available_time` |
| Flagged ⊆ computable | re-flag scopes match eligibility scopes (2026-09-10 machine-hour phantom backlog); the stranded sweep clears the rest |
| Targets respected | `target_customized` rows keep their `target` |

## Observability

- Freshness: `computed_at` and `source_watermark` on hour/shift/day/week/month rows.
- Backlog: `count(*) … WHERE recalc_needed` per grain within its window.
- Job health: `oeecloud_worker_job_ticks_total{job="runtime-rollup"|"runtime-rollup-hour-backfill"|"stranded-flag-sweep"}`.
- Logs: `runtime-rollup-hour failed`, `runtime-rollup-shift failed`, `runtime-rollup-shift draining
  backlog`, `job tick TIMED OUT`, `hour-backfill drained a batch`, `data-quality events recorded`,
  `silver invariant clamp CHANGED gold rows`, `stranded recalc flags cleared`.
- In-DB invariants (`ops.data_invariant_latest`, every 30 min) cross-check grains against Silver and
  the legacy oracle, e.g. C6 (line-lead shift gross vs the lead's Silver).
- In Postgres: `pg_stat_activity` for long `UPDATE gold.equipment_oee_shift`, `pg_locks` for advisory
  locks (`locktype = 'advisory'`).

## Failure modes

The incident table is on the [stream-engine](stream-engine.md#failure-modes) page. Patterns to
recognise:

| Pattern | Look at |
|---|---|
| Current shift reads 0, hourly and daily fine | shift batch starvation or rollback — the live row's `computed_at`, `draining backlog` logs, a burst of old flags |
| Everything stale at once | tick timeouts (a slow step rolls back that pass), provision holding `<dest>:runtime`, frozen cagg watermark |
| Old hours never change after a fix | outside the 10-day backfill horizon, not re-flagged, or the flag was cleared by the stranded sweep |
| Old shifts recomputed as "running the whole time" | flagged shifts older than 25 days: the state-only pass ran, the line-lead pass did not |
| Availability ~100% on an idle line | an open event without end (closer scope, trailing-event bound) |
| Availability 0 with production | no events and not in a count-based pass (line-lead / counters-avail lists) |
| Performance > 1 | the ideal speed is set too low (`IDEAL_SPEED_TOO_LOW` DQ event); not a rollup bug |
| OEE > what legacy shows by a constant factor | double writers or double sources (two publishers, a simulator on a real tenant) |

## Operating it

### Recomputing history safely

Use this after a code fix or a Silver repair. The full procedure is the runbook
[`docs/runbooks/history-recompute.md`](https://github.com/packiot/packiot-stack-alpha/blob/staging/docs/runbooks/history-recompute.md).

1. **Back up** the rows you will touch (`CREATE TABLE ops._bkp_<topic>_<date> AS SELECT …`).
2. **Fix Silver first**, then refresh the continuous aggregates over the affected range
   (`CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', from, to)`, then `_1hour`).
   The grains read the caggs, not Silver. On the shared DB:
   - never `decompress_chunk` (its ACCESS EXCLUSIVE lock stalled CPACK operator reads on
     2026-09-30); write row by row instead;
   - for DML on compressed chunks, set `SET timescaledb.max_tuples_decompressed_per_dml_transaction =
     0` and use **literal** timestamp bounds: a stable expression such as `date 'X' + 1` silently
     matched 0 rows on compressed chunks (2026-10-09). Read back every repair.
3. **Re-flag recent rows, don't recompute by hand.** Set `recalc_needed = true` on gold rows no older
   than ~7 days and let the jobs drain them with the same code as the live path:

   | Grain | Drained by | Reachable history |
   |---|---|---|
   | hour | backfill (`ROLLUP_BACKFILL_LIMIT` rows every `ROLLUP_BACKFILL_INTERVAL_SECONDS`) | 10 days |
   | shift | live `RunShift` (`ROLLUP_SHIFT_LIMIT` per minute) | 30 days; line-lead and reconcile 25 days |
   | day | live `RunDay` (all flagged) | 1 month |
   | week / month | `RunGrains` | 1 year |
   | area / site | `RunEntityGrains` | 1 month |

   Hour re-flags cascade to day; day to week/month. Re-flag shift rows yourself. Re-flag in slices
   (one day per statement) and watch the shift ticks.
4. **Only lines and sectors** (`tp_equipment > 1`) are recomputed at hour/day, plus machines of
   machine-level enterprises at shift. Flags on other rows are cleared by the stranded sweep.
   A repair script that flags "every grain of an equipment" must restrict the day grain to
   `tp_equipment > 1` (see `scripts/ops/repair-s2-stale-open-stops.sh`); a machine day row has no
   rollup, so flagging it changes nothing.
5. **Older than the windows**: re-flagging would run only the passes whose window still covers the
   row and leave a mixed state. Render the engine's own hour, shift and day passes widened to the
   repair horizon with `cmd/recompute-render`, and run them one day per transaction with
   `scripts/recompute/run-day-recompute.sh` (dry run = ROLLBACK first). The script's flag step and
   the passes run in the same transaction so no live pass drains rows half-way.
6. **Verify**: compare against Silver and the legacy oracle for closed periods; check
   `oee ≈ oee_a·oee_p·oee_q`, `computed_at` updated, no new `data_quality_event` rows, and
   `ops.data_invariant_latest` clean.

### Changing rollup SQL

- Keep the `*StatementsForParity` accessors in sync and extend the golden fixtures.
- `history.go` builds the recompute script from the same step lists, so a new step is picked up
  automatically; keep `history_test.go` passing.
- Any new step must fit in the 5-minute tick together with all other steps. Measure with the real line
  count (`EXPLAIN (ANALYZE, BUFFERS)` on staging), and prefer `LATERAL … OFFSET 0` per line/PO and
  `MATERIALIZED` CTEs where a CTE is referenced from a join (the #259 and 2026-09-24 lessons).
- A new flag-gated pass must not write rows another pass writes. A new `available_time` writer goes
  before the exclusions step.
- Relaxing or adding a bound needs the `*_oee_bounds` CHECK changed **before** the code deploys; a
  CHECK violation rolls back every rollup transaction.

## Tests

`DATABASE_URL=postgres://… go test -tags golden -run Golden ./internal/rollup/ ./internal/events/ ./internal/pocontrol/`
from `services/stream-engine` (CI job `golden-fixtures`). Rollup golden files: `golden_test.go`,
`shift_golden_test.go`, `line_lead_golden_test.go`, `counters_avail_golden_test.go`,
`changeover_golden_test.go`, `day_clamp_golden_test.go`, `hour_deadlock_golden_test.go`,
`provision_label_golden_test.go`,
`event_lookback_golden_test.go`, `availability_exclusions_golden_test.go`,
`availability_exclusions_po_golden_test.go`, `grain_cascade_golden_test.go`,
`area_day_flag_golden_test.go`, `po_runtime_golden_test.go`, `stranded_golden_test.go`,
`silver_clamp_golden_test.go`, `unmetered_golden_test.go`, `inferspeed_golden_test.go`. Plain unit
tests include `backfill_test.go`, `history_test.go`, `line_lead_scope_test.go`, `oee_test.go`,
`silver_test.go`, `dq_test.go`.

## Source map

| Path | What's there |
|---|---|
| `services/stream-engine/internal/rollup/hour.go` | `RunHour`, `fmtRD`, hour SQL |
| `services/stream-engine/internal/rollup/backfill.go` | `RunHourBackfill`, `widenHourWindows` |
| `services/stream-engine/internal/rollup/day.go` | `RunDay` |
| `services/stream-engine/internal/rollup/shift.go` | `RunShift`, fair-order eligibility |
| `services/stream-engine/internal/rollup/grains.go` | `RunGrains`, `LoopGrains` (the tick order) |
| `services/stream-engine/internal/rollup/entity_grains.go` | area/site grains |
| `services/stream-engine/internal/rollup/line_lead.go` | line-lead SQL, `eventsInEffectSQL`, planned predicate token |
| `services/stream-engine/internal/rollup/availability.go` | counters-avail, floor, canonical reconcile, `LineLeadScope`, `plannedDowntimeExpr` |
| `services/stream-engine/internal/rollup/availability_exclusions.go`, `availability_exclusions_po.go` | out-of-service / no-data exclusions |
| `services/stream-engine/internal/rollup/oee.go` | canonical OEE formulas in Go (reference) |
| `services/stream-engine/internal/rollup/dq.go`, `silver.go`, `unmetered.go`, `stranded.go` | post-grain passes and the stranded-flag sweep |
| `services/stream-engine/internal/rollup/history.go`, `cmd/recompute-render/` | history-recompute renderer |
| `services/stream-engine/internal/rollup/provision.go`, `locks.go` | provisioning (`provisionHourlySQL`: hour rows and their production-day label), advisory lock helper |
| `scripts/recompute/` | per-day recompute runner and flag example |
| `db/migrations/t-oee-uncapped-data/`, `t-history-uncap/` | relaxed OEE CHECKs, uncapped history |
| `db/migrations/t-data-invariants-v10/` | K7: day time above the production-day length (day times stored raw since 2026-10-13) |
| `db/migrations/t-data-invariants-v11/` | K8: hour rows per production day must equal the day's length / 3600 |
| `db/migrations/t-data-invariants-v12/` | K8 judged on settled days only (next day's start ≤ now), not the UTC date |
| `services/stream-engine/cmd/port-parity/`, `services/stream-engine/scripts/parity-check.sql` | parity tooling |
