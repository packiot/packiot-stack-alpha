-- t231 · PHASE 3 (GOLD, EXPAND) — reversal.
-- Drop the public shim views and move the grains back to public. Symmetric to
-- the up: chunks/policies/caggs/bi views follow by OID. Apply per-table with
-- lock_timeout+retry on the hot grains (same discipline as the up).
SET lock_timeout = '30s';

BEGIN; DROP VIEW IF EXISTS public.equipment_oee_shift;         ALTER TABLE gold.equipment_oee_shift         SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.equipment_oee_hourly;        ALTER TABLE gold.equipment_oee_hourly        SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.equipment_oee_daily;         ALTER TABLE gold.equipment_oee_daily         SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.equipment_oee_weekly;        ALTER TABLE gold.equipment_oee_weekly        SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.equipment_oee_monthly;       ALTER TABLE gold.equipment_oee_monthly       SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.equipment_oee_shift_weekly;  ALTER TABLE gold.equipment_oee_shift_weekly  SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.equipment_oee_shift_monthly; ALTER TABLE gold.equipment_oee_shift_monthly SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.area_oee_daily;              ALTER TABLE gold.area_oee_daily              SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.area_oee_shift;              ALTER TABLE gold.area_oee_shift              SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.site_oee_daily;              ALTER TABLE gold.site_oee_daily              SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.site_oee_shift;              ALTER TABLE gold.site_oee_shift              SET SCHEMA public; COMMIT;
BEGIN; DROP VIEW IF EXISTS public.production_orders_runtime;   ALTER TABLE gold.production_orders_runtime   SET SCHEMA public; COMMIT;

-- DROP SCHEMA IF EXISTS gold;  -- only when fully rolling back the medallion split
