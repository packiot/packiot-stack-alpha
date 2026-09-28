-- t-historian-serving-guards / 02 — HISTORIAN GATEWAY (packiot_historian, STAGING bucket).
-- Apply as postgres:
--   docker exec -i hist-gateway psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < 02-gateway-guards.sql
-- Idempotent. Rollback: rollback-02-gateway-guards.sql.

-- (1) Spike guard on the COLD raw view (2026-09-28 audit). The parquet stays untouched; the
-- view NULLs an increment that is physically impossible (same rule as
-- scripts/historian-ev-daily-rollup.sh):
--   * negative;
--   * > 10,000 and at least half the machine's lifetime totalizer (legacy wrote the totalizer
--     into the increment column: POLYTYPE net 2022-10..2023-09, ~1e12/month);
--   * > 10,000 and not backed by totalizer movement since the previous row (the 2024-07-22
--     replay: +74,367 every ~40 s, totalizer frozen); a counter reset keeps its increment
--     when it does not exceed the new totalizer;
--   * > 1,000 at more than 5,000 units/min when the machine has >= 3 such rows in the same
--     hour (sustained burst). A single fast row is a reconnect catch-up and is kept.
-- Windows partition by (enterprise, year, month, equipment[, hour]), so a year/month filter
-- still prunes the parquet (a day in a month: ~20 s). Measured on 10 CPACK months:
-- 2022-05, 2025-03, 2025-09, 2026-05 byte-identical; 2024-07-22 79 M -> 4.4 M gross.
CREATE OR REPLACE VIEW cold.equipment_values AS
WITH b AS (
  SELECT r['ts_value']::timestamp                     AS ts_value,
         r['enterprise']::int                         AS id_enterprise,
         r['year']::int                               AS year,
         r['month']::int                              AS month,
         r['id_equipment']::int                       AS id_equipment,
         r['gross_production_incr']::double precision AS gi,
         r['gross_production_val']::double precision  AS gv,
         r['net_production_incr']::double precision   AS ni,
         r['net_production_val']::double precision    AS nv,
         r['speed']::double precision                 AS speed
    FROM read_parquet('s3://packiot-staging-historian-639178078294/equipment_values/*/*/*/*-legacy.parquet',
                      hive_partitioning => true) r
), l AS (
  SELECT b.*,
         lag(gv) OVER wp AS pgv,
         lag(nv) OVER wp AS pnv,
         extract(epoch FROM ts_value - lag(ts_value) OVER wp) AS dt
    FROM b
  WINDOW wp AS (PARTITION BY id_enterprise, year, month, id_equipment ORDER BY ts_value)
), f AS (
  SELECT l.*,
         (gi > 1000 AND gi * 60.0 / greatest(coalesce(dt, 60), 1) > 5000) AS g_fast,
         (ni > 1000 AND ni * 60.0 / greatest(coalesce(dt, 60), 1) > 5000) AS n_fast
    FROM l
), h AS (
  SELECT f.*,
         count(*) FILTER (WHERE g_fast) OVER wh AS g_fast_h,
         count(*) FILTER (WHERE n_fast) OVER wh AS n_fast_h
    FROM f
  WINDOW wh AS (PARTITION BY id_enterprise, year, month, id_equipment, date_trunc('hour', ts_value))
)
SELECT ts_value, id_enterprise, year, month, id_equipment,
       CASE WHEN gi < 0
              OR (gi > 10000 AND gv > 0 AND gi >= 0.5 * gv)
              OR (gi > 10000 AND pgv IS NOT NULL AND CASE WHEN gv < pgv THEN gi > gv + 1 ELSE (gv - pgv) < 0.5 * gi END)
              OR (g_fast AND g_fast_h >= 3)
            THEN NULL ELSE gi END AS gross_production_incr,
       CASE WHEN ni < 0
              OR (ni > 10000 AND nv > 0 AND ni >= 0.5 * nv)
              OR (ni > 10000 AND pnv IS NOT NULL AND CASE WHEN nv < pnv THEN ni > nv + 1 ELSE (nv - pnv) < 0.5 * ni END)
              OR (n_fast AND n_fast_h >= 3)
            THEN NULL ELSE ni END AS net_production_incr,
       speed
  FROM h;

-- (2) Daily-rollup watermark: cold.equipment_values_daily covers whole UTC days < covered_until.
CREATE TABLE IF NOT EXISTS cold.ev_daily_watermark (
  id_enterprise int PRIMARY KEY,
  covered_until date NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE cold.ev_daily_watermark IS
  'Per enterprise: cold.equipment_values_daily holds every whole UTC day strictly before covered_until (written by scripts/historian-ev-daily-rollup.sh). read-api serves days before it from the rollup and days from it on from live.equipment_values_1hour.';

-- (3) HOT hourly rollup (analytics silver.equipment_categorical_1hour), pinned columns only.
DROP FOREIGN TABLE IF EXISTS live.equipment_values_1hour;
CREATE FOREIGN TABLE live.equipment_values_1hour (
  ts_value              timestamptz,
  id_enterprise         integer,
  id_equipment          integer,
  gross_production_incr double precision,
  net_production_incr   double precision
) SERVER live_pg OPTIONS (schema_name 'silver', table_name 'equipment_categorical_1hour');
COMMENT ON FOREIGN TABLE live.equipment_values_1hour IS
  'HOT hourly gross/net per equipment (analytics silver.equipment_categorical_1hour, 13-month retention). Sums equal the raw live.equipment_values sums. Always query with LITERAL time bounds: postgres_fdw never ships now() (a now()-bounded scan pulls the whole remote table).';

GRANT SELECT ON cold.ev_daily_watermark, live.equipment_values_1hour TO historian_svc;
