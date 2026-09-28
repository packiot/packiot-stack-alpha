-- t-historian-serving-guards / 02 — HISTORIAN GATEWAY (packiot_historian, STAGING bucket).
-- Apply as postgres:
--   docker exec -i hist-gateway psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < 02-gateway-guards.sql
-- Idempotent. Rollback: rollback-02-gateway-guards.sql.

-- (1) Spike guard on the COLD raw view (2026-09-28 audit). Legacy wrote the machine's
-- lifetime totalizer into the increment column in places (POLYTYPE net 2022-10..2023-09,
-- monthly sums ~1e12; the 2024-07-22 counter replay; 2026-08 gross ~3e10). An increment is
-- NULLed when it is negative, or at least half the totalizer AND above 10,000 in one row
-- (a counter reset keeps its small first increment). The parquet stays untouched. Checked
-- on 16 CPACK months: the 5 clean months are byte-identical; the garbage months drop back
-- to 90-140 M/month. Same rule as scripts/historian-ev-daily-rollup.sh.
CREATE OR REPLACE VIEW cold.equipment_values AS
SELECT r['ts_value']::timestamp               AS ts_value,
       r['enterprise']::int                   AS id_enterprise,
       r['year']::int                         AS year,
       r['month']::int                        AS month,
       r['id_equipment']::int                 AS id_equipment,
       CASE WHEN r['gross_production_incr']::double precision < 0
              OR (r['gross_production_val']::double precision > 0
                  AND r['gross_production_incr']::double precision >= 0.5 * r['gross_production_val']::double precision
                  AND r['gross_production_incr']::double precision > 10000)
            THEN NULL ELSE r['gross_production_incr']::double precision END AS gross_production_incr,
       CASE WHEN r['net_production_incr']::double precision < 0
              OR (r['net_production_val']::double precision > 0
                  AND r['net_production_incr']::double precision >= 0.5 * r['net_production_val']::double precision
                  AND r['net_production_incr']::double precision > 10000)
            THEN NULL ELSE r['net_production_incr']::double precision END   AS net_production_incr,
       r['speed']::double precision           AS speed
FROM read_parquet('s3://packiot-staging-historian-639178078294/equipment_values/*/*/*/*-legacy.parquet',
                  hive_partitioning => true) r;

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
