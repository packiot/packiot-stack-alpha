-- t-backfill-equipment-config-defaults
--
-- Fills two more new-stack onboarding-gap config columns with safe defaults
-- (same class as the threshold + cd_equipment gaps). Only touches NULLs.
--
--   net_production_type → 0 (sensors/counters). Distribution across the platform
--     is NULL=279, 0=4, and NEVER 1 (scanned boxes) — so sensors is universal and
--     matches the only explicit rows + the csadmin mapper default (?? 0). Making
--     it explicit is a no-op for behaviour (the OEE calc already treats it as
--     sensor-based) and removes the NULL.
--
--   stop_threshold_time → 300 (seconds; the micro-stop-vs-downtime threshold,
--     PLC param 30751). NULL for ent 1/2/4/5/119/120 (not CPACK, which is 301).
--     NULL/0 means "every stop is a full downtime"; 300s (5 min) is the standard
--     default and better than 0. Per-line tuning can still override in csadmin.
--
-- SAFE: core.equipments (analytics) has only set_updated_at; no packml regen.

BEGIN;

UPDATE core.equipments SET net_production_type = 0   WHERE net_production_type IS NULL;
UPDATE core.equipments SET stop_threshold_time = 300 WHERE stop_threshold_time IS NULL;

COMMIT;
