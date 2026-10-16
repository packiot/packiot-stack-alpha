-- ADR-0065 P3a step 2: give the categorical history max_speed by re-running silver.rollup_refresh one UTC day at a time
-- over the categorical retention (90 d), oldest first. Each call rewrites that day's rollups from silver.equipment_values
-- (identical sums; categorical now also carries max_speed). One transaction per day holding silver.rollup_tick's
-- advisory lock: the live tick (pg_try_advisory_xact_lock) skips while a day runs, so the two delete+insert passes can
-- never overlap (which could duplicate rows); a skipped tick is re-covered by the next one's 20-minute window. Re-runnable.
\set ON_ERROR_STOP 1
SET statement_timeout = '15min';
SELECT format('BEGIN; SELECT pg_advisory_xact_lock(hashtext(%L)); SELECT %L AS day, silver.rollup_refresh(%L::timestamptz, %L::timestamptz) AS rows; COMMIT;',
              'silver.rollup_tick', d::date, d, d + interval '1 day')
  FROM generate_series(date_trunc('day', now() - interval '91 days'), date_trunc('day', now()), interval '1 day') d
 WHERE EXISTS (SELECT 1 FROM silver.equipment_categorical_1min c WHERE c.ts_value >= d AND c.ts_value < d + interval '1 day'
                 AND c.max_speed IS NULL AND c.cnt_speed > 0)
 ORDER BY d \gexec
