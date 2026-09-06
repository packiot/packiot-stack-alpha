-- f3-close-stale-cpac-open-events-2026-09.sql
--
-- ONE-TIME backlog drain #2 of never-closed CPACK (status_type=0) OPEN
-- equipment_events. Supersedes f3-close-stale-cpac-open-events.sql, which ran in
-- the 2026-08-24 era; opens RE-ACCUMULATED (15,028 by 2026-09-04, oldest
-- 2026-06-22) because the recurring closer (stream-engine internal/events/
-- closer.go) had been silently failing on every tick — see below. This drains the
-- historical strand the recurring job's 72h horizon does not reach, using the
-- SAME logic the now-fixed closer runs.
--
-- ── WHY IT RE-ACCUMULATED (two compounding bugs, both fixed in closer.go) ──────
--  1. DECOMPRESSION CAP. equipment_events is a compressed hypertable; setting
--     ts_end on an open row in a compressed chunk forces TimescaleDB to decompress
--     the affected segments. A CPACK tick touches opens across dozens of chunks →
--     blows past max_tuples_decompressed_per_dml_transaction (100k) → SQLSTATE
--     53400 → the whole UPDATE aborts, closing ZERO. FIX: run the close in a tx
--     that SET LOCALs the cap to 0 (unlimited, tx-scoped).
--  2. SOURCE-CATEGORIZED OPENS. CPACK events arrive via mirror fan-out carrying
--     the source's category/notes but no ts_end. The old human-justified guard
--     gated EVERY close, so it mistook those source categories for staging-table
--     operator edits and refused to close them — even NON-LATEST opens whose end
--     is unambiguous. FIX: a next-event-bounded close (bounded_by_next) is pure
--     physics and bypasses the guard; the guard now protects only the TRAILING
--     count-silence close.
--
-- Each stale open (ts_end IS NULL) is read by the rollup as running/planned to
-- now() (COALESCE(ee.ts_end, now())). An open status=6 fabricates ~100%
-- availability; an open status=10 planned/downtime blankets available_time to 0 →
-- ideal_production=0 → net/ideal > 1 (the ent-3 tp=3 line-OEE bug, #187).
--
-- ── GUARD ────────────────────────────────────────────────────────────────────
-- Non-latest opens (a successor exists) close UNCONDITIONALLY at next_ts — filling
-- the missing ts_end never touches the category. The human-justified guard applies
-- ONLY to the trailing count-silence close, so an operator's genuinely-ongoing
-- downtime is never auto-closed. NULL-safe; does NOT gate on
-- forced_creation_system (true on every mirror row). Mirrors closer.go exactly.
--
-- Idempotent: only ts_end IS NULL rows are written; a second run is a no-op.
-- Parity-safe: scoped to id_enterprise=3 (status_type=0), inert elsewhere.
--
-- USAGE: dry-run first as written (ROLLBACK); inspect BEFORE/AFTER; then flip the
-- final ROLLBACK to COMMIT. Run against packiot_analytics.

\set ON_ERROR_STOP on
\set ent 3
\set thr_default 300

BEGIN;
-- Compressed-chunk safety: lift the per-tx decompression cap for this drain only.
SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
SET LOCAL statement_timeout = '600s';

\echo ===== BEFORE =====
SELECT status, count(*) AS open_rows
  FROM equipment_events WHERE id_enterprise = :ent AND ts_end IS NULL
 GROUP BY status ORDER BY status;
SELECT count(*) AS total_open, min(ts_event) AS oldest
  FROM equipment_events WHERE id_enterprise = :ent AND ts_end IS NULL;

-- ── STEP 1: close stale opens (mirrors closer.go; horizon = whole backlog) ────
WITH scope AS (
    SELECT id_equipment, COALESCE(NULLIF(stop_threshold_time, 0), :thr_default) AS thr
      FROM equipments
     WHERE status_type = 0 AND tp_equipment IN (1, 3) AND id_enterprise = :ent
), lastcount AS (
    SELECT s.id_equipment, s.thr, max(m.ts_value) AS last_ts
      FROM scope s
      JOIN ca_agg_equipment_values_1min m
        ON m.id_equipment = s.id_equipment AND m.gross_production_incr > 0
     GROUP BY s.id_equipment, s.thr
), open_ev AS (
    SELECT ev.id_equipment_event, ev.id_equipment, ev.ts_event,
           lead(ev.ts_event) OVER (PARTITION BY ev.id_equipment
               ORDER BY ev.ts_event, ev.id_equipment_event) AS next_ts
      FROM equipment_events ev
      JOIN scope s ON s.id_equipment = ev.id_equipment
), plan AS (
    SELECT o.id_equipment_event,
           CASE WHEN o.next_ts IS NOT NULL THEN o.next_ts
                ELSE greatest(o.ts_event, lc.last_ts + make_interval(secs => lc.thr))
           END AS new_end,
           (o.next_ts IS NOT NULL) AS bounded_by_next
      FROM open_ev o
      LEFT JOIN lastcount lc ON lc.id_equipment = o.id_equipment
     WHERE o.next_ts IS NOT NULL
        OR (lc.last_ts IS NOT NULL AND lc.last_ts + make_interval(secs => lc.thr) < now())
)
UPDATE equipment_events ev
   SET ts_end   = p.new_end,
       duration = extract(epoch FROM (p.new_end - ev.ts_event))::int,
       last_update = now()
  FROM plan p
 WHERE ev.id_equipment_event = p.id_equipment_event
   AND ev.ts_end IS NULL
   AND (p.bounded_by_next OR NOT (ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
        OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
        OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL));

-- ── STEP 2: reflag runtime grains so the deployed rollup/backfill recompute ───
-- Post-rename grain names (analytics v2 cutover): equipment_oee_hourly/_shift.
-- Closing an open event only REMOVES running-coverage, so a row already at
-- running_time=0 AND oee_a=0 stays 0 and needs no recompute — narrow to rows that
-- can change to keep the backfill drain small.
UPDATE equipment_oee_hourly e SET recalc_needed = true
  FROM equipments q
 WHERE e.id_equipment = q.id_equipment AND q.id_enterprise = :ent
   AND e.ts_value >= now() - interval '10 days'
   AND (e.running_time > 0 OR e.oee_a > 0);
UPDATE equipment_oee_shift e SET recalc_needed = true
  FROM equipments q
 WHERE e.id_equipment = q.id_equipment AND q.id_enterprise = :ent
   AND e.ts_value >= now() - interval '30 days'
   AND (e.running_time > 0 OR e.oee_a > 0);

\echo ===== AFTER (events closed; runtime recompute happens async in the worker) =====
SELECT status, count(*) AS open_rows
  FROM equipment_events WHERE id_enterprise = :ent AND ts_end IS NULL
 GROUP BY status ORDER BY status;
SELECT count(*) AS total_open_remaining, min(ts_event) AS oldest_remaining
  FROM equipment_events WHERE id_enterprise = :ent AND ts_end IS NULL;

-- Dry-run: change to COMMIT once BEFORE/AFTER look right.
ROLLBACK;
