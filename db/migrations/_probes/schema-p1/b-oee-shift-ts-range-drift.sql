-- schema-p1 probe (b): root cause of gold.equipment_oee_shift.ts_range drift. READ-ONLY, counts only.
-- 20,088 / 717,918 rows have ts_range <> tstzrange(ts_value, ts_end) (schema review 2026-10-06). Split them by:
--   pattern (which side differs), tenant, month of ts_value, size of the difference, and which side agrees with the
--   shift definition in core.shift_hours (length = end_time - begin_time seconds, mod one week; shift_hours times are
--   seconds from week_begin, so only the LENGTH is compared — no week-anchor math needed).
-- Two full reads of the table (~718k rows; compressed chunks are read in memory — no decompress_chunk).
-- (No temp view: CREATE is refused in a read-only transaction, so the drift CTE is repeated.)
\set ON_ERROR_STOP 1
SET default_transaction_read_only = on;
SET statement_timeout = '300s';
SET lock_timeout = '2s';

SELECT 'B0 totals: rows|drifted (ts_range IS DISTINCT FROM tstzrange(ts_value,ts_end))|ts_range NULL|ts_end NULL',
       count(*), count(*) FILTER (WHERE ts_range IS DISTINCT FROM tstzrange(ts_value, ts_end)),
       count(*) FILTER (WHERE ts_range IS NULL), count(*) FILTER (WHERE ts_end IS NULL)
  FROM gold.equipment_oee_shift;

-- B1..B5 in one pass. Read each row as: dimension|pattern|tenant|month|Δupper bucket|Δlower bucket|rows
-- (NULL in a column = "all"); 60 s = the #1545 1-minute clip, ±3600 s = a DST/timezone hour.
WITH d AS (
  SELECT e.id_enterprise,
         to_char(date_trunc('month', s.ts_value), 'YYYY-MM') AS month,
         CASE
           WHEN s.ts_range IS NULL                                  THEN 'ts_range NULL'
           WHEN s.ts_end IS NULL                                    THEN 'ts_end NULL (expected upper = inf)'
           WHEN lower(s.ts_range) IS DISTINCT FROM s.ts_value
            AND upper(s.ts_range) IS DISTINCT FROM s.ts_end         THEN 'both bounds differ'
           WHEN lower(s.ts_range) IS DISTINCT FROM s.ts_value       THEN 'lower differs'
           WHEN upper(s.ts_range) IS DISTINCT FROM s.ts_end         THEN 'upper differs'
           WHEN NOT lower_inc(s.ts_range) OR upper_inc(s.ts_range)  THEN 'inclusivity differs'
           ELSE 'other (empty range?)'
         END AS pattern,
         EXTRACT(epoch FROM upper(s.ts_range) - s.ts_end)   AS du,
         EXTRACT(epoch FROM lower(s.ts_range) - s.ts_value) AS dl
    FROM gold.equipment_oee_shift s
    JOIN core.equipments e ON e.id_equipment = s.id_equipment
   WHERE s.ts_range IS DISTINCT FROM tstzrange(s.ts_value, s.ts_end)
), b AS (
  SELECT *,
         CASE WHEN du IS NULL THEN 'n/a' WHEN du = 0 THEN '0' WHEN abs(du) = 60 THEN sign(du)::int || 'x60s'
              WHEN abs(du) = 3600 THEN sign(du)::int || 'x3600s' WHEN abs(du) < 3600 THEN sign(du)::int || 'x(<1h other)'
              WHEN abs(du) < 86400 THEN sign(du)::int || 'x(1h-1d)' ELSE sign(du)::int || 'x(>=1d)' END AS du_bucket,
         CASE WHEN dl IS NULL THEN 'n/a' WHEN dl = 0 THEN '0' WHEN abs(dl) = 60 THEN sign(dl)::int || 'x60s'
              WHEN abs(dl) = 3600 THEN sign(dl)::int || 'x3600s' WHEN abs(dl) < 3600 THEN sign(dl)::int || 'x(<1h other)'
              WHEN abs(dl) < 86400 THEN sign(dl)::int || 'x(1h-1d)' ELSE sign(dl)::int || 'x(>=1d)' END AS dl_bucket
    FROM d
)
SELECT CASE GROUPING(pattern, id_enterprise, month, du_bucket, dl_bucket)
         WHEN 15 THEN 'B1 pattern' WHEN 7 THEN 'B2 pattern x tenant' WHEN 11 THEN 'B3 pattern x month'
         WHEN 13 THEN 'B4 pattern x delta-upper' WHEN 14 THEN 'B5 pattern x delta-lower' ELSE 'B?' END AS dimension,
       pattern, id_enterprise, month, du_bucket, dl_bucket, count(*) AS rows
  FROM b
 GROUP BY GROUPING SETS ((pattern), (pattern, id_enterprise), (pattern, month), (pattern, du_bucket), (pattern, dl_bucket))
 ORDER BY 1, 2, 3, 4, 5, 6;

-- B6: which side is truth? compare both lengths with the shift definition and with the duration column.
WITH d AS (
  SELECT CASE
           WHEN s.ts_range IS NULL                                  THEN 'ts_range NULL'
           WHEN s.ts_end IS NULL                                    THEN 'ts_end NULL (expected upper = inf)'
           WHEN lower(s.ts_range) IS DISTINCT FROM s.ts_value
            AND upper(s.ts_range) IS DISTINCT FROM s.ts_end         THEN 'both bounds differ'
           WHEN lower(s.ts_range) IS DISTINCT FROM s.ts_value       THEN 'lower differs'
           WHEN upper(s.ts_range) IS DISTINCT FROM s.ts_end         THEN 'upper differs'
           WHEN NOT lower_inc(s.ts_range) OR upper_inc(s.ts_range)  THEN 'inclusivity differs'
           ELSE 'other (empty range?)'
         END AS pattern,
         EXTRACT(epoch FROM s.ts_end - s.ts_value)                 AS len_cols,
         EXTRACT(epoch FROM upper(s.ts_range) - lower(s.ts_range)) AS len_range,
         s.duration,
         CASE WHEN sh.id_shift_hour IS NULL THEN NULL
              ELSE ((sh.end_time - sh.begin_time) + 604800) % 604800 END AS len_sh,
         s.id_shift_hour IS NOT NULL AND sh.id_shift_hour IS NULL AS sh_missing,
         s.manually_customized, s.invalidated
    FROM gold.equipment_oee_shift s
    LEFT JOIN core.shift_hours sh ON sh.id_shift_hour = s.id_shift_hour
   WHERE s.ts_range IS DISTINCT FROM tstzrange(s.ts_value, s.ts_end)
)
SELECT 'B6 pattern|rows|no shift_hours row|id_shift_hour dangling|ts_end side = shift_hours only|ts_range side = shift_hours only|both match|neither|duration = ts_end side|duration = range side|manually_customized|invalidated',
       pattern, count(*),
       count(*) FILTER (WHERE len_sh IS NULL),
       count(*) FILTER (WHERE sh_missing),
       count(*) FILTER (WHERE len_cols = len_sh AND len_range IS DISTINCT FROM len_sh),
       count(*) FILTER (WHERE len_range = len_sh AND len_cols IS DISTINCT FROM len_sh),
       count(*) FILTER (WHERE len_cols = len_sh AND len_range = len_sh),
       count(*) FILTER (WHERE len_sh IS NOT NULL AND len_cols IS DISTINCT FROM len_sh AND len_range IS DISTINCT FROM len_sh),
       count(*) FILTER (WHERE duration = len_cols),
       count(*) FILTER (WHERE duration = len_range),
       count(*) FILTER (WHERE manually_customized),
       count(*) FILTER (WHERE invalidated)
  FROM d GROUP BY 2 ORDER BY 2;

-- B7 (informational, for the follow-up EXCLUDE — review #10): overlapping shift windows of the same equipment,
-- last 90 days, on each definition. A non-zero first number means an EXCLUDE on ts_range would fail today.
SELECT 'B7 overlapping pairs (last 90 d): on ts_range | on tstzrange(ts_value,ts_end)',
       count(*) FILTER (WHERE a.ts_range && b.ts_range),
       count(*) FILTER (WHERE tstzrange(a.ts_value, a.ts_end) && tstzrange(b.ts_value, b.ts_end))
  FROM gold.equipment_oee_shift a
  JOIN gold.equipment_oee_shift b
    ON b.id_equipment = a.id_equipment AND b.id_runtime_shift > a.id_runtime_shift
   AND b.ts_value >= now() - interval '120 days'
   AND b.ts_value < a.ts_value + interval '2 days' AND b.ts_value > a.ts_value - interval '2 days'
 WHERE a.ts_value >= now() - interval '90 days';
