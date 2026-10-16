-- Set AVAILABILITY_EXCLUSIONS_ENABLED=false (or roll back stream-engine) FIRST.
-- Then recompute the affected rows (reflag) — available_time stays reduced until
-- the writers rerun.
BEGIN;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['equipment_oee_hourly', 'equipment_oee_shift', 'equipment_oee_daily',
                           'equipment_oee_weekly', 'equipment_oee_monthly',
                           'area_oee_daily', 'area_oee_shift', 'site_oee_shift'] LOOP
    EXECUTE format('ALTER TABLE gold.%I DROP COLUMN IF EXISTS no_data_time, DROP COLUMN IF EXISTS out_of_service_time', t);
  END LOOP;
END $$;
DROP TABLE IF EXISTS config.equipment_out_of_service;
COMMIT;
