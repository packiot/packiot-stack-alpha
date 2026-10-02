\pset pager off
\set ON_ERROR_STOP off
CREATE SCHEMA IF NOT EXISTS silver;
COMMENT ON SCHEMA silver IS 'SILVER medallion tier — ONE hierarchical cagg family (equipment x time grain). Promoted from analytics_v2 PoC, 2026-09-08 (analytics clean-schema redesign P1). Decomposable numeric partials only; avg=Σsum/Σcnt exact at every tier.';

-- Tier 1: 1-minute on RAW equipment_values
CREATE MATERIALIZED VIEW IF NOT EXISTS silver.equipment_metrics_1min
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT time_bucket('1 minute', ts_value) AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(net_production_incr::float8) AS sum_net, sum(gross_production_incr::float8) AS sum_gross,
  sum(scrap_incr::float8) AS sum_scrap, sum(speed::float8) AS sum_speed, count(speed) AS cnt_speed,
  count(*) AS cnt_rows, max(speed::float8) AS max_speed, max(ideal_production_speed) AS ideal_production_speed
  -- NOTE: partials are float8 (not the float4 source type) so the telescoping rollup is exactly
  -- equal to a float8 direct-RAW sum. float4 partials lost ~4.8e-6 rel precision on large buckets
  -- (fixed 2026-09-08, P3 pre-fix — see 10_p3pre_silver_float8_partials.sql).
FROM public.equipment_values WHERE tp_equipment IS NOT NULL
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

-- Tier 2: 10-minute on tier 1
CREATE MATERIALIZED VIEW IF NOT EXISTS silver.equipment_metrics_10min
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT time_bucket('10 minutes', bucket) AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(sum_net) AS sum_net, sum(sum_gross) AS sum_gross, sum(sum_scrap) AS sum_scrap,
  sum(sum_speed) AS sum_speed, sum(cnt_speed) AS cnt_speed, sum(cnt_rows) AS cnt_rows,
  max(max_speed) AS max_speed, max(ideal_production_speed) AS ideal_production_speed
FROM silver.equipment_metrics_1min
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

-- Tier 3: 1-hour on tier 2
CREATE MATERIALIZED VIEW IF NOT EXISTS silver.equipment_metrics_1hour
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT time_bucket('1 hour', bucket) AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(sum_net) AS sum_net, sum(sum_gross) AS sum_gross, sum(sum_scrap) AS sum_scrap,
  sum(sum_speed) AS sum_speed, sum(cnt_speed) AS cnt_speed, sum(cnt_rows) AS cnt_rows,
  max(max_speed) AS max_speed, max(ideal_production_speed) AS ideal_production_speed
FROM silver.equipment_metrics_10min
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

-- Tier 4: 1-day on tier 3
CREATE MATERIALIZED VIEW IF NOT EXISTS silver.equipment_metrics_1day
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT time_bucket('1 day', bucket) AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(sum_net) AS sum_net, sum(sum_gross) AS sum_gross, sum(sum_scrap) AS sum_scrap,
  sum(sum_speed) AS sum_speed, sum(cnt_speed) AS cnt_speed, sum(cnt_rows) AS cnt_rows,
  max(max_speed) AS max_speed, max(ideal_production_speed) AS ideal_production_speed
FROM silver.equipment_metrics_1hour
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

GRANT USAGE ON SCHEMA silver TO superset_ro, bi_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA silver TO superset_ro, bi_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON TABLES TO superset_ro, bi_owner;
\echo === silver caggs created ===
SELECT view_name FROM timescaledb_information.continuous_aggregates WHERE view_schema='silver' ORDER BY 1;
