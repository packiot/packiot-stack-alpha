-- Rollback for 02-gateway-guards.sql (+ 03 daily view). Restores the unguarded cold view.
DROP VIEW IF EXISTS cold.equipment_values_daily;
DROP FOREIGN TABLE IF EXISTS live.equipment_values_1hour;
DROP TABLE IF EXISTS cold.ev_daily_watermark;
CREATE OR REPLACE VIEW cold.equipment_values AS
SELECT r['ts_value']::timestamp               AS ts_value,
       r['enterprise']::int                   AS id_enterprise,
       r['year']::int                         AS year,
       r['month']::int                        AS month,
       r['id_equipment']::int                 AS id_equipment,
       r['gross_production_incr']::double precision AS gross_production_incr,
       r['net_production_incr']::double precision   AS net_production_incr,
       r['speed']::double precision           AS speed
FROM read_parquet('s3://packiot-staging-historian-639178078294/equipment_values/*/*/*/*-legacy.parquet',
                  hive_partitioning => true) r;
