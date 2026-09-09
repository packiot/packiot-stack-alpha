-- t237 P-silver — ROLLBACK: drop the public shim views + move the 9 grains silver → public.
-- Symmetric to 01-expand.sql (catalog-only; no data at risk — SET SCHEMA moves rows+indexes by OID).
-- Run this AFTER reverting the stream-engine GrainSchema/route.grain flip back to "public"
-- (otherwise the deployed engine's uns/pocontrol sink would write silver.* with no table there).

BEGIN;
SET LOCAL lock_timeout = '3s';

DROP VIEW IF EXISTS public.equipment_live_day;
DROP VIEW IF EXISTS public.equipment_live_hour;
DROP VIEW IF EXISTS public.equipment_live_job;
DROP VIEW IF EXISTS public.equipment_live_month;
DROP VIEW IF EXISTS public.equipment_live_shift;
DROP VIEW IF EXISTS public.equipment_live_week;
DROP VIEW IF EXISTS public.area_live_day;
DROP VIEW IF EXISTS public.area_live_shift;
DROP VIEW IF EXISTS public.site_live_day;

ALTER TABLE silver.equipment_live_day   SET SCHEMA public;
ALTER TABLE silver.equipment_live_hour  SET SCHEMA public;
ALTER TABLE silver.equipment_live_job   SET SCHEMA public;
ALTER TABLE silver.equipment_live_month SET SCHEMA public;
ALTER TABLE silver.equipment_live_shift SET SCHEMA public;
ALTER TABLE silver.equipment_live_week  SET SCHEMA public;
ALTER TABLE silver.area_live_day        SET SCHEMA public;
ALTER TABLE silver.area_live_shift      SET SCHEMA public;
ALTER TABLE silver.site_live_day        SET SCHEMA public;

COMMIT;
