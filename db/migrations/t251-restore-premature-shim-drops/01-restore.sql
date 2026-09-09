-- t251 — RESTORE the medallion public shims that t249/t250 dropped PREMATURELY, and
-- record the genuinely-dead objects that stay dropped. SUPERSEDES t249 + t250.
--
-- WHY: the #248 rollup de-shim was INCOMPLETE — it repointed rollup/ + events/ to
-- silver/gold directly, but stream-engine's OTHER jobs still read via EvSchema=public:
--   uns/current_metrics.go, uns po-runtime-refresh, rollup/dq.go (data-quality scan),
--   rollup/silver.go (invariant clamp), rollup/compute.go (PO-runtime), and the
--   entity-grains area/site-day flag. Those qualify %[1]s(=public).<table>, so dropping
--   the shims broke them (42P01 on uns/dq/po-refresh/silver-clamp/area-day-flag ticks).
-- So these shims are LOAD-BEARING until the WHOLE stream-engine is de-shimmed. Restore them.
--
-- Gold-backed grain shims:
CREATE OR REPLACE VIEW public.equipment_oee_hourly  AS SELECT * FROM gold.equipment_oee_hourly;
CREATE OR REPLACE VIEW public.equipment_oee_shift   AS SELECT * FROM gold.equipment_oee_shift;
CREATE OR REPLACE VIEW public.equipment_oee_daily   AS SELECT * FROM gold.equipment_oee_daily;
CREATE OR REPLACE VIEW public.equipment_oee_weekly  AS SELECT * FROM gold.equipment_oee_weekly;
CREATE OR REPLACE VIEW public.equipment_oee_monthly AS SELECT * FROM gold.equipment_oee_monthly;
CREATE OR REPLACE VIEW public.equipment_oee_shift_monthly AS SELECT * FROM gold.equipment_oee_shift_monthly;
CREATE OR REPLACE VIEW public.equipment_oee_shift_weekly  AS SELECT * FROM gold.equipment_oee_shift_weekly;
CREATE OR REPLACE VIEW public.area_oee_shift        AS SELECT * FROM gold.area_oee_shift;
CREATE OR REPLACE VIEW public.area_oee_daily        AS SELECT * FROM gold.area_oee_daily;
CREATE OR REPLACE VIEW public.site_oee_daily        AS SELECT * FROM gold.site_oee_daily;
CREATE OR REPLACE VIEW public.site_oee_shift        AS SELECT * FROM gold.site_oee_shift;
CREATE OR REPLACE VIEW public.production_orders_runtime AS SELECT * FROM gold.production_orders_runtime;
-- Silver-backed fact + live-grain shims:
CREATE OR REPLACE VIEW public.equipment_values      AS SELECT * FROM silver.equipment_values;
CREATE OR REPLACE VIEW public.equipment_events      AS SELECT * FROM silver.equipment_events;
CREATE OR REPLACE VIEW public.equipment_live_metrics AS SELECT * FROM silver.equipment_live_metrics;
CREATE OR REPLACE VIEW public.area_live_day     AS SELECT * FROM silver.area_live_day;
CREATE OR REPLACE VIEW public.area_live_shift   AS SELECT * FROM silver.area_live_shift;
CREATE OR REPLACE VIEW public.site_live_day     AS SELECT * FROM silver.site_live_day;
CREATE OR REPLACE VIEW public.equipment_live_day   AS SELECT * FROM silver.equipment_live_day;
CREATE OR REPLACE VIEW public.equipment_live_shift AS SELECT * FROM silver.equipment_live_shift;
-- Core-backed dim shim:
CREATE OR REPLACE VIEW public.production_orders AS SELECT * FROM core.production_orders;
--
-- GENUINELY-DEAD objects (stay dropped — 0 rows, 0 deps, 0 consumers, superseded):
--   public.h_piot_oee_score_teams_table  (superseded by serving.oee_score)
--   schema drop_backup_20260908          (validated-migration rollback snapshot)
-- t248's public.equipment_categorical_{1min,1hour} ALSO stay dropped — the ROLLUP
-- (which read them) IS de-shimmed to silver.equipment_categorical; no other consumer.
