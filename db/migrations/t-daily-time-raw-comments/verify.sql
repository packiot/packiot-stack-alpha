-- verify for t-daily-time-raw-comments. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
\pset format unaligned
\t on
SELECT 'daily_time_comments_saying_capped_at_bucket (expect 0)|' || count(*)
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'gold' AND c.relname IN ('equipment_oee_daily','area_oee_daily') AND a.attnum > 0
   AND col_description(c.oid, a.attnum) ~* 'capped at (the )?bucket span';
SELECT 'daily_time_comments_stored_raw (expect 10)|' || count(*)
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'gold' AND c.relname IN ('equipment_oee_daily','area_oee_daily')
   AND a.attname IN ('available_time','running_time','planned_downtime','downtime','changeover_time')
   AND col_description(c.oid, a.attnum) LIKE '%Stored RAW%';
SELECT 'hourly_running_time_still_bucket_capped (expect 1)|' || count(*)
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'gold' AND c.relname = 'equipment_oee_hourly' AND a.attname = 'running_time'
   AND col_description(c.oid, a.attnum) LIKE '%capped at the bucket span%';
