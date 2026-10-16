\pset pager off
-- P3 PRE-FIX: silver partials real(float4) -> double precision(float8).
-- The float4 accumulator loses ~4.8e-6 relative precision on large buckets and,
-- because the family telescopes (1min->10min->1hour->1day), that error compounds.
-- Cast the RAW source to float8 in tier-1 so every stored partial is float8 and
-- the rollup is exactly equal to a float8 direct-RAW sum. Additive-safe: silver is
-- not yet consumed (aggregate serving fns still read legacy agg_*).
-- Reverse: DROP + re-run 04_p1_silver_metrics_family.sql (real partials).

-- serving.machine_speed reads tier-1 => drop it first, recreate after (verbatim from 07_p2).
DROP VIEW IF EXISTS serving.machine_speed;

-- Drop top-down (higher tiers depend on lower). Refresh policies drop with the cagg.
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_metrics_1day;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_metrics_1hour;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_metrics_10min;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_metrics_1min;

-- Tier 1: 1-minute on RAW equipment_values (source cast to float8)
CREATE MATERIALIZED VIEW silver.equipment_metrics_1min
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT time_bucket('1 minute', ts_value) AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(net_production_incr::float8)   AS sum_net,
  sum(gross_production_incr::float8) AS sum_gross,
  sum(scrap_incr::float8)           AS sum_scrap,
  sum(speed::float8)                AS sum_speed,
  count(speed)                      AS cnt_speed,
  count(*)                          AS cnt_rows,
  max(speed::float8)                AS max_speed,
  max(ideal_production_speed)       AS ideal_production_speed
FROM public.equipment_values WHERE tp_equipment IS NOT NULL
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

-- Tier 2: 10-minute on tier 1
CREATE MATERIALIZED VIEW silver.equipment_metrics_10min
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
CREATE MATERIALIZED VIEW silver.equipment_metrics_1hour
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
CREATE MATERIALIZED VIEW silver.equipment_metrics_1day
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

-- Recreate serving.machine_speed verbatim (07_p2_serving_layer.sql).
CREATE OR REPLACE VIEW serving.machine_speed WITH (security_invoker=true) AS
SELECT eq.id_enterprise, m.id_equipment, eq.nm_equipment, m.bucket AS ts_value,
  (m.sum_speed / NULLIF(m.cnt_speed,0)) AS speed, m.max_speed AS plc_speed_max,
  eq.production_speed AS ideal_production_speed,
  m.sum_gross, m.sum_net, m.sum_scrap, m.cnt_rows, m.tp_equipment,
  eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
FROM silver.equipment_metrics_1min m JOIN public.equipments eq ON eq.id_equipment = m.id_equipment;
GRANT SELECT ON serving.machine_speed TO superset_ro, bi_owner;

\echo === partial types after recreate (expect double precision) ===
SELECT a.attname, format_type(a.atttypid,a.atttypmod) type
FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='silver' AND c.relname='equipment_metrics_1min'
  AND a.attname IN ('sum_net','sum_gross','sum_scrap','sum_speed','max_speed') ORDER BY 1;
