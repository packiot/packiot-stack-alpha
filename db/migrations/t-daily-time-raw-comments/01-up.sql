-- t-daily-time-raw-comments — the day-grain time columns are stored RAW since PR #1723
-- (2026-10-13, "remove the day-length cap like P and Q"): equipment_oee_daily time columns
-- are the plain Σ of the production day's hour rows, and area_oee_daily is the plain Σ of its
-- lines' day rows. Only oee_a stays capped (at 1). The t278b comments on these columns were
-- copied from the hour grain and still say "capped at the bucket span (LEAST)", which is
-- false at the day grain. Comment-only; no data or DDL change.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

-- gold.equipment_oee_daily — Σ of the hour rows labelled with this production day.
COMMENT ON COLUMN gold.equipment_oee_daily.available_time IS 'Scheduled production time in SECONDS = Σ available_time of the hour rows labelled with this production day. Stored RAW, never capped at the day length (PR #1723, 2026-10-13). Each hour row is bounded by its own hour bucket; a day above its DST-aware length is a data-quality signal surfaced by invariant K7_day_time_gt_day_length, not clipped. Denominator of Availability (oee_a is the one value capped, at 1).';
COMMENT ON COLUMN gold.equipment_oee_daily.running_time IS 'Time in the RUNNING state (equipment_events status=6) in SECONDS = Σ running_time of the hour rows labelled with this production day. Stored RAW, never capped at the day length (PR #1723, 2026-10-13; over-length days surface in invariant K7_day_time_gt_day_length). Numerator of Availability: oee_a = LEAST(running_time / available_time, 1).';
COMMENT ON COLUMN gold.equipment_oee_daily.planned_downtime IS 'Time in PLANNED-downtime events in SECONDS = Σ planned_downtime of the hour rows labelled with this production day (each hour row bounded by its hour bucket). Stored RAW, never capped at the day grain. Excluded from available_time.';
COMMENT ON COLUMN gold.equipment_oee_daily.downtime IS 'Time in ANY non-running state (equipment_events status <> 6) in SECONDS = Σ downtime of the hour rows labelled with this production day. Stored RAW, never capped at the day length (PR #1723, 2026-10-13; over-length days surface in invariant K7_day_time_gt_day_length).';
COMMENT ON COLUMN gold.equipment_oee_daily.changeover_time IS 'Time in CHANGEOVER events (change_over=true) in SECONDS = Σ changeover_time of the hour rows labelled with this production day (each hour row bounded by its hour bucket). Stored RAW, never capped at the day grain.';

-- gold.area_oee_daily — Σ of the area's line (tp_equipment=3) equipment_oee_daily rows.
COMMENT ON COLUMN gold.area_oee_daily.available_time IS 'Scheduled production time in SECONDS = Σ available_time of the area''s line (tp_equipment=3) equipment_oee_daily rows for this day. Stored RAW, never capped (several lines legitimately exceed one day length). Denominator of Availability; oee_a is capped at 1.';
COMMENT ON COLUMN gold.area_oee_daily.running_time IS 'Time in the RUNNING state (equipment_events status=6) in SECONDS = Σ running_time of the area''s line (tp_equipment=3) equipment_oee_daily rows for this day. Stored RAW, never capped (PR #1723, 2026-10-13). Numerator of Availability; oee_a is capped at 1.';
COMMENT ON COLUMN gold.area_oee_daily.planned_downtime IS 'Time in PLANNED-downtime events in SECONDS = Σ planned_downtime of the area''s line (tp_equipment=3) equipment_oee_daily rows for this day. Stored RAW, never capped. Excluded from available_time.';
COMMENT ON COLUMN gold.area_oee_daily.downtime IS 'Time in ANY non-running state (equipment_events status <> 6) in SECONDS = Σ downtime of the area''s line (tp_equipment=3) equipment_oee_daily rows for this day. Stored RAW, never capped (PR #1723, 2026-10-13).';
COMMENT ON COLUMN gold.area_oee_daily.changeover_time IS 'Time in CHANGEOVER events (change_over=true) in SECONDS = Σ changeover_time of the area''s line (tp_equipment=3) equipment_oee_daily rows for this day. Stored RAW, never capped.';

COMMIT;
