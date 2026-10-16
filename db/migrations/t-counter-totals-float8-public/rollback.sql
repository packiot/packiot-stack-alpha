-- rollback: set COUNTER_TOTALS_PUBLIC=false and restart stream-engine FIRST (else every insert fails), same window.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE public.equipment_values
  DROP COLUMN IF EXISTS gross_production_total, DROP COLUMN IF EXISTS net_production_total,
  DROP COLUMN IF EXISTS scrap_total, DROP COLUMN IF EXISTS process_scrap_total;
DO $$ BEGIN
  IF to_regclass('public.equipment_values_raw') IS NOT NULL THEN
    ALTER TABLE public.equipment_values_raw
      DROP COLUMN IF EXISTS gross_production_total, DROP COLUMN IF EXISTS net_production_total,
      DROP COLUMN IF EXISTS scrap_total, DROP COLUMN IF EXISTS process_scrap_total;
  END IF;
END $$;
COMMIT;
