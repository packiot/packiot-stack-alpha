-- 13_p4_rename_runtime_uns_subordinate_objects.sql
-- P4 step 2: rename subordinate objects (constraints/indexes/sequence) on the
-- already-renamed equipment_oee_*/equipment_live_*/area_*/site_* tables so their
-- names follow the meaningful-names cutover (runtime_->oee_, uns_->live_).
-- BEHAVIOR-NEUTRAL: renames are OID-tracked (PKs used via column-inference ON
-- CONFLICT in edge-api; FKs/indexes by OID). Hardproofed: 0 fn bodies reference
-- any of these names (0 ON CONSTRAINT refs; 0 name-string refs). production_orders_runtime
-- is NOT renamed (correctly named) so its subordinate objects are left untouched.
-- Reverse: swap old<->new in each statement.
BEGIN;
ALTER TABLE public.area_live_day RENAME CONSTRAINT uns_area_current_day_pkey TO area_live_day_pkey;
ALTER TABLE public.area_live_shift RENAME CONSTRAINT uns_area_current_shift_pkey TO area_live_shift_pkey;
ALTER TABLE public.area_oee_daily RENAME CONSTRAINT area_runtime_1day_pk TO area_oee_daily_pk;
ALTER TABLE public.area_oee_shift RENAME CONSTRAINT area_runtime_shift_oee_bounds TO area_oee_shift_oee_bounds;
ALTER TABLE public.area_oee_shift RENAME CONSTRAINT area_runtime_shift_pk TO area_oee_shift_pk;
ALTER TABLE public.area_oee_shift RENAME CONSTRAINT chk_area_runtime_shift_ts_order TO chk_area_oee_shift_ts_order;
ALTER TABLE public.equipment_live_day RENAME CONSTRAINT uns_equipment_current_day_pkey TO equipment_live_day_pkey;
ALTER TABLE public.equipment_live_hour RENAME CONSTRAINT uns_equipment_current_hour_pkey TO equipment_live_hour_pkey;
ALTER TABLE public.equipment_live_job RENAME CONSTRAINT uns_equipment_current_job_id_equipment_fkey TO equipment_live_job_id_equipment_fkey;
ALTER TABLE public.equipment_live_job RENAME CONSTRAINT uns_equipment_current_job_pkey TO equipment_live_job_pkey;
ALTER TABLE public.equipment_live_metrics RENAME CONSTRAINT uns_equipment_current_metrics_id_equipment_key TO equipment_live_metrics_id_equipment_key;
ALTER TABLE public.equipment_live_metrics RENAME CONSTRAINT uns_equipment_current_metrics_pk TO equipment_live_metrics_pk;
ALTER TABLE public.equipment_live_month RENAME CONSTRAINT uns_equipment_current_month_pkey TO equipment_live_month_pkey;
ALTER TABLE public.equipment_live_shift RENAME CONSTRAINT uns_equipment_current_shift_pkey TO equipment_live_shift_pkey;
ALTER TABLE public.equipment_live_week RENAME CONSTRAINT uns_equipment_current_week_pkey TO equipment_live_week_pkey;
ALTER TABLE public.equipment_oee_daily RENAME CONSTRAINT equipment_runtime_1day_oee_bounds TO equipment_oee_daily_oee_bounds;
ALTER TABLE public.equipment_oee_daily RENAME CONSTRAINT equipment_runtime_1day_pkey TO equipment_oee_daily_pkey;
ALTER TABLE public.equipment_oee_hourly RENAME CONSTRAINT equipment_runtime_1hour_oee_bounds TO equipment_oee_hourly_oee_bounds;
ALTER TABLE public.equipment_oee_hourly RENAME CONSTRAINT equipment_runtime_1hour_pkey TO equipment_oee_hourly_pkey;
ALTER TABLE public.equipment_oee_monthly RENAME CONSTRAINT equipment_runtime_1month_pkey TO equipment_oee_monthly_pkey;
ALTER TABLE public.equipment_oee_shift RENAME CONSTRAINT chk_equipment_runtime_shift_ts_order TO chk_equipment_oee_shift_ts_order;
ALTER TABLE public.equipment_oee_shift RENAME CONSTRAINT equipment_runtime_shift_oee_bounds TO equipment_oee_shift_oee_bounds;
ALTER TABLE public.equipment_oee_shift RENAME CONSTRAINT equipment_runtime_shift_pk TO equipment_oee_shift_pk;
ALTER TABLE public.equipment_oee_weekly RENAME CONSTRAINT equipment_runtime_1week_pkey TO equipment_oee_weekly_pkey;
ALTER TABLE public.site_live_day RENAME CONSTRAINT uns_site_current_day_pkey TO site_live_day_pkey;
ALTER TABLE public.site_oee_daily RENAME CONSTRAINT site_runtime_1day_pk TO site_oee_daily_pk;
ALTER TABLE public.site_oee_shift RENAME CONSTRAINT chk_site_runtime_shift_ts_order TO chk_site_oee_shift_ts_order;
ALTER TABLE public.site_oee_shift RENAME CONSTRAINT site_runtime_shift_oee_bounds TO site_oee_shift_oee_bounds;
ALTER TABLE public.site_oee_shift RENAME CONSTRAINT site_runtime_shift_pk TO site_oee_shift_pk;
ALTER INDEX public.equipment_runtime_1hour_id_equipment_idx RENAME TO equipment_oee_hourly_id_equipment_idx;
ALTER INDEX public.equipment_runtime_1hour_ts_value_idx RENAME TO equipment_oee_hourly_ts_value_idx;
ALTER INDEX public.equipment_runtime_shift_1month_pk RENAME TO equipment_oee_shift_monthly_pk;
ALTER INDEX public.equipment_runtime_shift_1week_pk RENAME TO equipment_oee_shift_weekly_pk;
ALTER INDEX public.equipment_runtime_shift_ts_range_id_equipment_idx RENAME TO equipment_oee_shift_ts_range_id_equipment_idx;
ALTER INDEX public.equipment_runtime_shift_ts_value_idx RENAME TO equipment_oee_shift_ts_value_idx;
ALTER SEQUENCE public.equipment_runtime_shift_id_seq RENAME TO equipment_oee_shift_id_seq;
COMMIT;
