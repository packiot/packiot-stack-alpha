-- rollback for t-daily-time-raw-comments — restores the exact t278b text (read from staging 2026-10-14).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
COMMENT ON COLUMN gold.area_oee_daily.available_time IS 'Scheduled production time in SECONDS = bucket wall-clock span - planned_downtime (LEAST-guarded >= 0). Denominator of Availability.';
COMMENT ON COLUMN gold.area_oee_daily.running_time IS 'Time in the RUNNING state (equipment_events status=6) in SECONDS, capped at the bucket span (LEAST) so overlapping line/member events cannot exceed elapsed wall-clock.';
COMMENT ON COLUMN gold.area_oee_daily.planned_downtime IS 'Time in PLANNED-downtime events in SECONDS (capped at the bucket span). Subtracted from wall-clock to yield available_time.';
COMMENT ON COLUMN gold.area_oee_daily.downtime IS 'Time in ANY non-running state (equipment_events status <> 6) in SECONDS (capped at bucket span).';
COMMENT ON COLUMN gold.area_oee_daily.changeover_time IS 'Time in CHANGEOVER events (change_over=true) in SECONDS (capped at bucket span).';
COMMENT ON COLUMN gold.equipment_oee_daily.available_time IS 'Scheduled production time in SECONDS = bucket wall-clock span - planned_downtime (LEAST-guarded >= 0). Denominator of Availability.';
COMMENT ON COLUMN gold.equipment_oee_daily.running_time IS 'Time in the RUNNING state (equipment_events status=6) in SECONDS, capped at the bucket span (LEAST) so overlapping line/member events cannot exceed elapsed wall-clock.';
COMMENT ON COLUMN gold.equipment_oee_daily.planned_downtime IS 'Time in PLANNED-downtime events in SECONDS (capped at the bucket span). Subtracted from wall-clock to yield available_time.';
COMMENT ON COLUMN gold.equipment_oee_daily.downtime IS 'Time in ANY non-running state (equipment_events status <> 6) in SECONDS (capped at bucket span).';
COMMENT ON COLUMN gold.equipment_oee_daily.changeover_time IS 'Time in CHANGEOVER events (change_over=true) in SECONDS (capped at bucket span).';
COMMIT;
