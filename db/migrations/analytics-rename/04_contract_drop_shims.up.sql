-- analytics-rename CONTRACT PHASE (applied 2026-09-04): drop the 33 compat shims
-- after ALL consumers deployed on canonical names + 4-min live 42P01 watch CLEAN.
-- Reversible via 04_contract_drop_shims.down.sql.
BEGIN;
DROP VIEW IF EXISTS public.equipment_runtime_shift_1month;
DROP VIEW IF EXISTS public.uns_equipment_current_metrics;
DROP VIEW IF EXISTS public.equipment_runtime_shift_1week;
DROP VIEW IF EXISTS public.uns_equipment_current_shift;
DROP VIEW IF EXISTS public.uns_equipment_current_month;
DROP VIEW IF EXISTS public.uns_equipment_current_week;
DROP VIEW IF EXISTS public.uns_equipment_current_hour;
DROP VIEW IF EXISTS public.uns_equipment_current_job;
DROP VIEW IF EXISTS public.uns_equipment_current_day;
DROP VIEW IF EXISTS public.equipment_runtime_1month;
DROP VIEW IF EXISTS public.equipment_runtime_shift;
DROP VIEW IF EXISTS public.equipment_runtime_1week;
DROP VIEW IF EXISTS public.equipment_runtime_1hour;
DROP VIEW IF EXISTS public.uns_site_current_month;
DROP VIEW IF EXISTS public.uns_area_current_shift;
DROP VIEW IF EXISTS public.uns_area_current_month;
DROP VIEW IF EXISTS public.equipment_runtime_1day;
DROP VIEW IF EXISTS public.uns_site_current_week;
DROP VIEW IF EXISTS public.uns_site_current_hour;
DROP VIEW IF EXISTS public.uns_area_current_week;
DROP VIEW IF EXISTS public.uns_area_current_hour;
DROP VIEW IF EXISTS public.uns_site_current_day;
DROP VIEW IF EXISTS public.uns_area_current_day;
DROP VIEW IF EXISTS public.site_runtime_1month;
DROP VIEW IF EXISTS public.area_runtime_1month;
DROP VIEW IF EXISTS public.site_runtime_shift;
DROP VIEW IF EXISTS public.site_runtime_1week;
DROP VIEW IF EXISTS public.site_runtime_1hour;
DROP VIEW IF EXISTS public.area_runtime_shift;
DROP VIEW IF EXISTS public.area_runtime_1week;
DROP VIEW IF EXISTS public.area_runtime_1hour;
DROP VIEW IF EXISTS public.site_runtime_1day;
DROP VIEW IF EXISTS public.area_runtime_1day;
COMMIT;
