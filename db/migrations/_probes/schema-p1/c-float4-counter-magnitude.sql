-- schema-p1 probe (c): how close are the float4 (real) counters to the exact-integer limit? READ-ONLY, max/counts only.
-- silver.equipment_values / bronze.equipment_values_raw store cumulative PLC totalizers (*_val) and per-sample
-- increments (*_incr) as real: 24-bit mantissa → integers are exact only up to 2^24 = 16,777,216; above that the
-- spacing is 2 (then 4 above 2^25, … 128 above 2^31). The stream-engine seeds its increment clamp from the stored
-- *_val on restart (writers/totalizer_seed.go), so a rounded _val leaks into the first increment after a restart.
-- Time-filtered to the last 30 days so only recent chunks are read (chunk exclusion on ts_value); compressed chunks
-- are read in memory — no decompress_chunk. Per tenant: max of each column and how many rows exceed 2^24.
\set ON_ERROR_STOP 1
SET default_transaction_read_only = on;
SET statement_timeout = '600s';
SET lock_timeout = '2s';

SELECT 'C1 silver.equipment_values last 30 d: id_enterprise|rows|equipments|max gross_val|max net_val|max scrap_val|max process_scrap_val|rows gross_val>2^24|net_val>2^24|scrap_val>2^24|process_scrap_val>2^24|equipments with any _val>2^24',
       id_enterprise, count(*), count(DISTINCT id_equipment),
       max(gross_production_val), max(net_production_val), max(scrap_val), max(process_scrap_val),
       count(*) FILTER (WHERE gross_production_val > 16777216),
       count(*) FILTER (WHERE net_production_val > 16777216),
       count(*) FILTER (WHERE scrap_val > 16777216),
       count(*) FILTER (WHERE process_scrap_val > 16777216),
       count(DISTINCT id_equipment) FILTER (WHERE greatest(gross_production_val, net_production_val, scrap_val, process_scrap_val) > 16777216)
  FROM silver.equipment_values
 WHERE ts_value >= now() - interval '30 days'
 GROUP BY id_enterprise ORDER BY id_enterprise;

SELECT 'C2 silver.equipment_values last 30 d increments: id_enterprise|max gross_incr|max net_incr|max scrap_incr|max process_scrap_incr|min of any incr|rows any abs(incr)>2^24',
       id_enterprise,
       max(gross_production_incr), max(net_production_incr), max(scrap_incr), max(process_scrap_incr),
       least(min(gross_production_incr), min(net_production_incr), min(scrap_incr), min(process_scrap_incr)),
       count(*) FILTER (WHERE greatest(abs(gross_production_incr), abs(net_production_incr), abs(scrap_incr), abs(process_scrap_incr)) > 16777216)
  FROM silver.equipment_values
 WHERE ts_value >= now() - interval '30 days'
 GROUP BY id_enterprise ORDER BY id_enterprise;

SELECT 'C3 bronze.equipment_values_raw last 30 d: id_enterprise|rows|equipments|max gross_val|max net_val|max scrap_val|max process_scrap_val|rows gross_val>2^24|net_val>2^24|scrap_val>2^24|process_scrap_val>2^24|equipments with any _val>2^24',
       id_enterprise, count(*), count(DISTINCT id_equipment),
       max(gross_production_val), max(net_production_val), max(scrap_val), max(process_scrap_val),
       count(*) FILTER (WHERE gross_production_val > 16777216),
       count(*) FILTER (WHERE net_production_val > 16777216),
       count(*) FILTER (WHERE scrap_val > 16777216),
       count(*) FILTER (WHERE process_scrap_val > 16777216),
       count(DISTINCT id_equipment) FILTER (WHERE greatest(gross_production_val, net_production_val, scrap_val, process_scrap_val) > 16777216)
  FROM bronze.equipment_values_raw
 WHERE ts_value >= now() - interval '30 days'
 GROUP BY id_enterprise ORDER BY id_enterprise;

SELECT 'C4 bronze.equipment_values_raw last 30 d increments: id_enterprise|max gross_incr|max net_incr|max scrap_incr|max process_scrap_incr|min of any incr|rows any abs(incr)>2^24',
       id_enterprise,
       max(gross_production_incr), max(net_production_incr), max(scrap_incr), max(process_scrap_incr),
       least(min(gross_production_incr), min(net_production_incr), min(scrap_incr), min(process_scrap_incr)),
       count(*) FILTER (WHERE greatest(abs(gross_production_incr), abs(net_production_incr), abs(scrap_incr), abs(process_scrap_incr)) > 16777216)
  FROM bronze.equipment_values_raw
 WHERE ts_value >= now() - interval '30 days'
 GROUP BY id_enterprise ORDER BY id_enterprise;

-- headroom: how many equipments are within 2x of the limit (> 2^23 = 8,388,608) — the ones that cross it next
SELECT 'C5 silver last 30 d: equipments with max _val in (2^23, 2^24] | > 2^24 (per tenant)',
       id_enterprise,
       count(*) FILTER (WHERE mv > 8388608 AND mv <= 16777216), count(*) FILTER (WHERE mv > 16777216)
  FROM (SELECT id_enterprise, id_equipment,
               greatest(max(gross_production_val), max(net_production_val), max(scrap_val), max(process_scrap_val)) AS mv
          FROM silver.equipment_values WHERE ts_value >= now() - interval '30 days'
         GROUP BY 1, 2) x
 GROUP BY id_enterprise ORDER BY id_enterprise;
