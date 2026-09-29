-- Uncapped OEE data (2026-09-29 clamp audit; user decision "store raw, clamp only in UI").
-- Drops the UPPER bounds of the *_oee_bounds CHECKs on oee, oee_p, oee_q:
--   P > 1  = the configured ideal speed is too low (a signal the UI now shows);
--   Q > 1  = at the hour grain, units in transit between the infeed (gross) and
--            outfeed (net) sensors; over a shift/day it points at a meter problem.
-- Availability keeps [0,1]: running time cannot exceed available time by definition.
-- Lower bounds stay (a negative ratio is not a measurement).
-- MUST be applied BEFORE the stream-engine writers stop capping: a CHECK violation
-- rolls back the whole rollup transaction and freezes OEE for every tenant.
-- NOT VALID + VALIDATE: the ADD is instant; the scan runs under SHARE UPDATE EXCLUSIVE.
ALTER TABLE gold.production_orders_runtime DROP CONSTRAINT production_orders_runtime_oee_bounds, ADD CONSTRAINT production_orders_runtime_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.equipment_oee_hourly DROP CONSTRAINT equipment_oee_hourly_oee_bounds, ADD CONSTRAINT equipment_oee_hourly_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.equipment_oee_daily DROP CONSTRAINT equipment_oee_daily_oee_bounds, ADD CONSTRAINT equipment_oee_daily_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.equipment_oee_monthly DROP CONSTRAINT equipment_oee_monthly_oee_bounds, ADD CONSTRAINT equipment_oee_monthly_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.area_oee_daily DROP CONSTRAINT area_oee_daily_oee_bounds, ADD CONSTRAINT area_oee_daily_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.area_oee_shift DROP CONSTRAINT area_oee_shift_oee_bounds, ADD CONSTRAINT area_oee_shift_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.site_oee_shift DROP CONSTRAINT site_oee_shift_oee_bounds, ADD CONSTRAINT site_oee_shift_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.equipment_oee_shift DROP CONSTRAINT equipment_oee_shift_oee_bounds, ADD CONSTRAINT equipment_oee_shift_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.equipment_oee_shift_weekly DROP CONSTRAINT equipment_oee_shift_weekly_oee_bounds, ADD CONSTRAINT equipment_oee_shift_weekly_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.equipment_oee_shift_monthly DROP CONSTRAINT equipment_oee_shift_monthly_oee_bounds, ADD CONSTRAINT equipment_oee_shift_monthly_oee_bounds CHECK (oee >= 0 AND oee_a >= 0 AND oee_a <= 1 AND oee_p >= 0 AND oee_q >= 0) NOT VALID;
ALTER TABLE gold.production_orders_runtime VALIDATE CONSTRAINT production_orders_runtime_oee_bounds;
ALTER TABLE gold.equipment_oee_hourly VALIDATE CONSTRAINT equipment_oee_hourly_oee_bounds;
ALTER TABLE gold.equipment_oee_daily VALIDATE CONSTRAINT equipment_oee_daily_oee_bounds;
ALTER TABLE gold.equipment_oee_monthly VALIDATE CONSTRAINT equipment_oee_monthly_oee_bounds;
ALTER TABLE gold.area_oee_daily VALIDATE CONSTRAINT area_oee_daily_oee_bounds;
ALTER TABLE gold.area_oee_shift VALIDATE CONSTRAINT area_oee_shift_oee_bounds;
ALTER TABLE gold.site_oee_shift VALIDATE CONSTRAINT site_oee_shift_oee_bounds;
ALTER TABLE gold.equipment_oee_shift VALIDATE CONSTRAINT equipment_oee_shift_oee_bounds;
ALTER TABLE gold.equipment_oee_shift_weekly VALIDATE CONSTRAINT equipment_oee_shift_weekly_oee_bounds;
ALTER TABLE gold.equipment_oee_shift_monthly VALIDATE CONSTRAINT equipment_oee_shift_monthly_oee_bounds;
