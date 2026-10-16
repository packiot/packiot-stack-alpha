-- verify for t-prodt170-operator-events-windows. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SET statement_timeout = '5min';
SELECT 'V1 enterprises without a valid window (want 0)', count(*) FROM core.enterprises
 WHERE operator_pending_window NOT IN ('shift', 'production_day', 'hours') OR operator_history_window NOT IN ('shift', 'production_day', 'hours')
    OR operator_pending_hours NOT BETWEEN 1 AND 168 OR operator_history_hours NOT BETWEEN 1 AND 168;
SELECT 'V2 window settings in use (default: production_day/24 hours/24)', operator_pending_window || '/' || operator_pending_hours || ' ' ||
       operator_history_window || '/' || operator_history_hours, count(*) FROM core.enterprises GROUP BY 2 ORDER BY 3 DESC;
SELECT 'V3 the four CHECKs exist (want 4)', count(*) FROM pg_constraint
 WHERE conrelid = 'core.enterprises'::regclass AND conname LIKE 'enterprises_operator_%_check';
-- every active LINE: its windows are within [now - 7 d, now], and the production day is the calendar's, not UTC midnight
SELECT 'V4 lines with a window start outside [now-7d, now] (want 0)', count(*)
  FROM core.equipments e, serving.operator_events_window_by_equipment(ARRAY[e.id_equipment]) w
 WHERE e.active AND e.tp_equipment = 3
   AND (w.pending_start NOT BETWEEN now() - interval '7 days' AND now() OR w.history_start NOT BETWEEN now() - interval '7 days' AND now());
SELECT 'V5 per enterprise: pending window start of its lines (production day starts at the site day_begin)', e.id_enterprise,
       min(w.pending_start), max(w.pending_start), count(*)
  FROM core.equipments e, serving.operator_events_window_by_equipment(ARRAY[e.id_equipment]) w
 WHERE e.active AND e.tp_equipment = 3 GROUP BY 2 ORDER BY 2;
-- every pending row is in its window or ongoing; every history row started in its window
SELECT 'V6 pending rows outside the window and not ongoing (want 0)', count(*)
  FROM core.equipments e
  CROSS JOIN LATERAL serving.pending_downtime_by_equipment(ARRAY[e.id_equipment]) d
  CROSS JOIN LATERAL serving.operator_events_window_by_equipment(ARRAY[e.id_equipment]) w
 WHERE e.active AND e.tp_equipment = 3 AND d.id_equipment = w.id_equipment AND d.ts_event < w.pending_start AND d.ts_end IS NOT NULL;
SELECT 'V7 history rows started before the window (want 0)', count(*)
  FROM core.equipments e
  CROSS JOIN LATERAL serving.events_timeline_by_equipment(ARRAY[e.id_equipment]) t
  CROSS JOIN LATERAL serving.operator_events_window_by_equipment(ARRAY[e.id_equipment]) w
 WHERE e.active AND e.tp_equipment = 3 AND t.id_equipment = w.id_equipment AND t.ts_event < w.history_start;
SELECT 'V8 readapi_ro can execute (want t|t|t)', has_function_privilege('readapi_ro', 'serving.operator_events_window_by_equipment(integer[])', 'EXECUTE'),
       has_function_privilege('readapi_ro', 'serving.pending_downtime_by_equipment(integer[])', 'EXECUTE'),
       has_function_privilege('readapi_ro', 'serving.events_timeline_by_equipment(integer[])', 'EXECUTE');
SELECT 'V9 prod_reflector may update the new columns (want t, or no role)', CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prod_reflector')
       THEN has_column_privilege('prod_reflector', 'core.enterprises', 'operator_history_hours', 'UPDATE')::text ELSE 'no role' END;
