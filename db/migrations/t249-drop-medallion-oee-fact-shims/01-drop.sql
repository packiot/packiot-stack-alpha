-- t249 — drop 9 orphaned public→gold/silver medallion shim views (#249).
-- These pass-through views (public.<name> → gold/silver.<name>) are now unreferenced:
--   * stream-engine reads gold/silver DIRECTLY (#248 de-shim).
--   * every OTHER consumer (read-api, analytics-sync, mirror-worker) uses BARE names,
--     which resolve to gold/silver via the DB search_path (gold,silver,... precede public),
--     NOT the public shim — verified: to_regclass('equipment_oee_shift') → gold, etc.
--   * serving.oee_score repointed public.equipment_oee_shift → gold.equipment_oee_shift.
--   * 0 DB view/matview dependents; Hasura absent; Superset has no dataset on these
--     (its only PO dataset is bi.production_orders).
-- Applied live on staging 2026-09-09; stream-engine + read-api verified healthy after.
-- NOT dropped: public.production_orders — pervasively QUALIFIED (74 files packiot-stack +
-- 7 edge-api, PO control-plane); its drop needs a dedicated whole-stack repoint (follow-up).
DROP VIEW IF EXISTS public.equipment_oee_hourly;
DROP VIEW IF EXISTS public.equipment_oee_shift;
DROP VIEW IF EXISTS public.equipment_oee_daily;
DROP VIEW IF EXISTS public.equipment_oee_weekly;
DROP VIEW IF EXISTS public.equipment_oee_monthly;
DROP VIEW IF EXISTS public.area_oee_shift;
DROP VIEW IF EXISTS public.production_orders_runtime;
DROP VIEW IF EXISTS public.equipment_values;
DROP VIEW IF EXISTS public.equipment_events;
