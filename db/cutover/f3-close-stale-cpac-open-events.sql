-- f3-close-stale-cpac-open-events.sql
--
-- ONE-TIME backlog close of never-closed CPACK (status_type=0) OPEN
-- equipment_events on the LIVE table, + a recalc reflag so the deployed rollup /
-- backfill re-read the now-bounded events. Companion to the recurring
-- events-close-stale job (stream-engine internal/events/closer.go) which keeps
-- the tail closed going forward. This drains the historical strand the recurring
-- job's bounded horizon does not reach.
--
-- ── THE BUG ──────────────────────────────────────────────────────────────────
-- CPACK events on public.equipment_events are written by the mirror fan-out
-- (FanoutEventRow) — a one-shot per-row upsert with NO closer. The status_type=4
-- deriver skips them (wrong status_type); the CPAC count-silence deriver that
-- WOULD bound them writes only to the DARK equipment_events_cpac_shadow table.
-- So CPACK open (ts_end IS NULL) status=6 rows are never closed and accumulate
-- (5.9k open status=6 on staging by 2026-08-24, oldest 08-13). The rollup treats
-- an open event as running to now() (hour.go/shift.go: COALESCE(ee.ts_end,
-- now())), so ONE stale open status=6 makes every subsequent idle hour read
-- running_time = full-hour → oee_a = 1.0 — fabricated ~100% availability on
-- dead/idle lines, which pass Grafana's running_time>0 guard and crush the OEE
-- headline (6.2% vs the real producing-lines ~14-23%).
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--  STEP 1 — close every in-scope open row deterministically (identical logic to
--  closer.go, wide horizon = the whole backlog):
--    (a) NON-LATEST open → ts_end = lead(ts_event): an interval ends when the
--        next transition begins (pure gaps-and-islands; always correct).
--    (b) TRAILING open (no successor) → count-silence close at
--        greatest(ts_event, last_productive_minute + stop_threshold), ONLY once
--        that grace has elapsed. greatest() collapses a count-less phantom run to
--        zero duration; a real run that went quiet settles at last-count+grace; a
--        still-live machine (last count + thr in the future) is LEFT OPEN.
--
--  STEP 2 — reflag recalc_needed=TRUE on the affected runtime grains so the
--  DEPLOYED rollup (shift: 30-day live loop) and backfill (hour: 10-day, gated by
--  ROLLUP_BACKFILL_ENABLED, on since #883) recompute running_time/oee_a from the
--  now-bounded events. The grain-column reconcile (f3-hour-shift-day-oee-reconcile)
--  cannot do this — it recomputes oee FROM the stored running_time, so it needs
--  the running_time itself re-derived from source first, which only the event-
--  reading rollup can do.
--
-- ── GUARD (never clobber an operator edit) ───────────────────────────────────
-- Only rows with NO human justification/reclassification are closed:
--   cd_category / cd_subcategory / cd_machine / txt_downtime_notes all NULL AND
--   planned_downtime IS NOT TRUE AND change_over IS NOT TRUE AND idle IS NULL.
-- The guard is NULL-SAFE (planned_downtime/change_over are NULL on live system
-- rows) and deliberately does NOT gate on forced_creation_system — that column is
-- TRUE on every live mirror-fan-out system row (prod's normal derived flag), so
-- gating on it would skip 100% of the backlog. See closer.go humanJustifiedPred.
--
-- Idempotent: only ts_end IS NULL rows are written; a second run is a no-op.
-- Parity-safe: scoped to id_enterprise=3 (status_type=0), inert elsewhere.
--
-- USAGE: dry-run first as written (ROLLBACK); inspect BEFORE/AFTER; then flip the
-- final ROLLBACK to COMMIT.

\set ON_ERROR_STOP on
\set ent 3
\set thr_default 300

BEGIN;

\echo ===== BEFORE =====
-- open status=6 (the fabrication driver) + open status=10, and justified opens
SELECT status, count(*) AS open_rows
  FROM equipment_events WHERE id_enterprise = :ent AND ts_end IS NULL
 GROUP BY status ORDER BY status;
SELECT count(*) AS justified_open_preserved
  FROM equipment_events
 WHERE id_enterprise = :ent AND ts_end IS NULL
   AND (cd_category IS NOT NULL OR cd_subcategory IS NOT NULL OR cd_machine IS NOT NULL
        OR txt_downtime_notes IS NOT NULL OR planned_downtime IS TRUE OR change_over IS TRUE
        OR idle IS NOT NULL);
-- fabricated idle hours: net=0 hour rows reading oee_a>0.99 (last 10 days)
SELECT count(*) AS fabricated_a099_idle_hours_10d
  FROM equipment_runtime_1hour r JOIN equipments e ON e.id_equipment = r.id_equipment
 WHERE e.id_enterprise = :ent AND r.ts_value >= now() - interval '10 days'
   AND r.oee_a > 0.99 AND COALESCE(r.net, 0) = 0;

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
           END AS new_end
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
   AND NOT (ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
        OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
        OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL);

-- ── STEP 2: reflag runtime grains so the deployed rollup/backfill recompute ───
-- Narrowed to rows that CAN change: closing an open event only ever REMOVES
-- running-coverage, so a row already at running_time=0 AND oee_a=0 stays 0 and
-- needs no recompute. Skipping them keeps the backfill backlog small (bounded
-- per-tick drain) without missing any affected row.
-- HOUR (backfill horizon = 10 days; tp_equipment>1 lines/sectors are what the
-- backfill and Grafana read for CPACK).
UPDATE equipment_runtime_1hour e SET recalc_needed = true
  FROM equipments q
 WHERE e.id_equipment = q.id_equipment AND q.id_enterprise = :ent
   AND e.ts_value >= now() - interval '10 days'
   AND (e.running_time > 0 OR e.oee_a > 0);
-- SHIFT (live shift loop horizon = 30 days; panel-3 reads this grain).
UPDATE equipment_runtime_shift e SET recalc_needed = true
  FROM equipments q
 WHERE e.id_equipment = q.id_equipment AND q.id_enterprise = :ent
   AND e.ts_value >= now() - interval '30 days'
   AND (e.running_time > 0 OR e.oee_a > 0);

\echo ===== AFTER (events closed; runtime recompute happens async in the worker) =====
SELECT status, count(*) AS open_rows
  FROM equipment_events WHERE id_enterprise = :ent AND ts_end IS NULL
 GROUP BY status ORDER BY status;
-- The only opens that should remain: genuinely-live trailing rows + the
-- justified opens we intentionally preserved.
SELECT count(*) AS justified_open_still_intact
  FROM equipment_events
 WHERE id_enterprise = :ent AND ts_end IS NULL
   AND (cd_category IS NOT NULL OR cd_subcategory IS NOT NULL OR cd_machine IS NOT NULL
        OR txt_downtime_notes IS NOT NULL OR planned_downtime IS TRUE OR change_over IS TRUE
        OR idle IS NOT NULL);
SELECT count(*) AS hour_rows_reflagged
  FROM equipment_runtime_1hour e JOIN equipments q ON q.id_equipment = e.id_equipment
 WHERE q.id_enterprise = :ent AND e.recalc_needed AND e.ts_value >= now() - interval '10 days'
   AND (e.running_time > 0 OR e.oee_a > 0);
SELECT count(*) AS shift_rows_reflagged
  FROM equipment_runtime_shift e JOIN equipments q ON q.id_equipment = e.id_equipment
 WHERE q.id_enterprise = :ent AND e.recalc_needed AND e.ts_value >= now() - interval '30 days'
   AND (e.running_time > 0 OR e.oee_a > 0);

-- Dry-run: change to COMMIT once BEFORE/AFTER look right.
ROLLBACK;
