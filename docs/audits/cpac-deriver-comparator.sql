-- cpac-deriver-comparator.sql — ADR-0010 §10.4 GAP-1 enablement GATE.
--
-- Diffs the DARK CPAC deriver's output (equipment_events_cpac_shadow) against
-- the mirrored-prod CPAC events (equipment_events, fanned in by mirror-worker
-- FanoutEventRow = LEGACY CPAC ground truth) for CPACK (enterprise 3) over a
-- full shift. Run this on F3 (packiot_shadow) AFTER enabling the deriver on
-- staging for a bake. The deriver stays DARK until this shows acceptable
-- convergence; then per-equipment stop_threshold_time is tuned and the target
-- is retargeted to the real equipment_events.
--
-- GROUND-TRUTH RULE: legacy CPAC (prod PLC state) is authoritative. The count-
-- silence deriver CANNOT see sub-cadence stops (< ~count p95, ~90–460s) that the
-- PLC state signal catches, and its ts boundaries are grace-shifted — so allow
-- the documented ts_end convergence tolerance (:tol_sec, default 120s). The GATE
-- is about STOP COUNT + STOP-TIME convergence, not byte-identity.
--
-- Usage:
--   psql "$F3_URL" -v ent=3 -v win="'25 hours'" -v tol_sec=120 \
--        -f docs/audits/cpac-deriver-comparator.sql
\pset pager off
\set ent :ent
\if :{?win}
\else
  \set win '25 hours'
\endif
\if :{?tol_sec}
\else
  \set tol_sec 120
\endif

\echo ==== 0. window + params ====
SELECT :ent AS enterprise, (:'win')::interval AS window, :tol_sec AS ts_tolerance_sec;

\echo ==== 1. STOP-COUNT convergence per equipment (derived status=10 vs ground truth) ====
WITH derived AS (
  SELECT id_equipment, count(*) n
    FROM public.equipment_events_cpac_shadow
   WHERE id_enterprise = :ent AND status = 10 AND ts_event > now() - (:'win')::interval
   GROUP BY 1),
truth AS (
  SELECT id_equipment, count(*) n
    FROM public.equipment_events
   WHERE id_enterprise = :ent AND status = 10 AND ts_event > now() - (:'win')::interval
   GROUP BY 1)
SELECT COALESCE(d.id_equipment, t.id_equipment) AS id_equipment,
       COALESCE(d.n,0) AS derived_stops, COALESCE(t.n,0) AS truth_stops,
       COALESCE(d.n,0) - COALESCE(t.n,0) AS delta
  FROM derived d FULL OUTER JOIN truth t USING (id_equipment)
 ORDER BY abs(COALESCE(d.n,0) - COALESCE(t.n,0)) DESC;

\echo ==== 2. STOP-TIME convergence: total downtime seconds derived vs truth ====
WITH d AS (
  SELECT id_equipment, sum(COALESCE(duration, extract(epoch FROM now()-ts_event))) secs
    FROM public.equipment_events_cpac_shadow
   WHERE id_enterprise = :ent AND status = 10 AND ts_event > now() - (:'win')::interval
   GROUP BY 1),
t AS (
  SELECT id_equipment, sum(COALESCE(duration, extract(epoch FROM now()-ts_event))) secs
    FROM public.equipment_events
   WHERE id_enterprise = :ent AND status = 10 AND ts_event > now() - (:'win')::interval
   GROUP BY 1)
SELECT COALESCE(d.id_equipment,t.id_equipment) id_equipment,
       round(COALESCE(d.secs,0))  derived_stop_s,
       round(COALESCE(t.secs,0))  truth_stop_s,
       round(COALESCE(d.secs,0) - COALESCE(t.secs,0)) delta_s,
       CASE WHEN COALESCE(t.secs,0) > 0
            THEN round(100.0*(COALESCE(d.secs,0)-COALESCE(t.secs,0))/t.secs, 1) END AS delta_pct
  FROM d FULL OUTER JOIN t USING (id_equipment)
 ORDER BY abs(COALESCE(d.secs,0)-COALESCE(t.secs,0)) DESC;

\echo ==== 3. MATCHED stops within ts tolerance (each derived stop paired to a truth stop) ====
WITH d AS (SELECT id_equipment, ts_event FROM public.equipment_events_cpac_shadow
             WHERE id_enterprise=:ent AND status=10 AND ts_event > now()-(:'win')::interval),
     t AS (SELECT id_equipment, ts_event FROM public.equipment_events
             WHERE id_enterprise=:ent AND status=10 AND ts_event > now()-(:'win')::interval)
SELECT
  (SELECT count(*) FROM d) AS derived_total,
  (SELECT count(*) FROM t) AS truth_total,
  count(*) FILTER (WHERE m.ts_event IS NOT NULL) AS derived_matched
  FROM d
  LEFT JOIN LATERAL (
     SELECT 1 AS ts_event FROM t
      WHERE t.id_equipment = d.id_equipment
        AND abs(extract(epoch FROM t.ts_event - d.ts_event)) <= :tol_sec
      LIMIT 1) m ON true;

\echo ==== 4. GATE verdict (aggregate): stop-count + downtime-second convergence ====
WITH d AS (SELECT count(*) n, sum(COALESCE(duration,0)) s FROM public.equipment_events_cpac_shadow
             WHERE id_enterprise=:ent AND status=10 AND ts_event > now()-(:'win')::interval AND ts_end IS NOT NULL),
     t AS (SELECT count(*) n, sum(COALESCE(duration,0)) s FROM public.equipment_events
             WHERE id_enterprise=:ent AND status=10 AND ts_event > now()-(:'win')::interval AND ts_end IS NOT NULL)
SELECT d.n derived_closed_stops, t.n truth_closed_stops,
       round(d.s) derived_closed_s, round(t.s) truth_closed_s,
       CASE WHEN t.s>0 THEN round(100.0*(d.s-t.s)/t.s,1) END AS downtime_delta_pct,
       CASE WHEN t.n>0 THEN round(100.0*(d.n-t.n)/t.n,1) END AS stopcount_delta_pct
  FROM d, t;
