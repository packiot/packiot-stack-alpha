-- verify for t-counter-totals-cagg-deprecation. Read-only; label|value, expected value in the label.
\set ON_ERROR_STOP 1
SELECT 'V1 cagg *_val columns marked DEPRECATED (4 caggs x 3): 12',
       count(*) FROM pg_attribute a
        WHERE a.attrelid IN ('silver.agg_equipment_values_1min'::regclass, 'silver.agg_equipment_values_1hour'::regclass,
                             'silver.equipment_categorical_1min'::regclass, 'silver.equipment_categorical_1hour'::regclass)
          AND a.attname IN ('net_production_val', 'gross_production_val', 'scrap_val')
          AND col_description(a.attrelid, a.attnum) LIKE 'DEPRECATED (float4%';
SELECT 'V2 original comment text kept after the prefix: 12',
       count(*) FROM pg_attribute a
        WHERE a.attrelid IN ('silver.agg_equipment_values_1min'::regclass, 'silver.agg_equipment_values_1hour'::regclass,
                             'silver.equipment_categorical_1min'::regclass, 'silver.equipment_categorical_1hour'::regclass)
          AND a.attname IN ('net_production_val', 'gross_production_val', 'scrap_val')
          AND col_description(a.attrelid, a.attnum) ~ '(\(totalizer count\)|totalizer value in the bucket \(count\))\.$';
SELECT 'V3 caggs still present and refreshing (jobs): 4',
       count(DISTINCT hypertable_name) FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_refresh_continuous_aggregate'
          -- a cagg's refresh job is listed under the cagg VIEW name (not its materialization hypertable)
          AND hypertable_schema = 'silver'
          AND hypertable_name IN ('agg_equipment_values_1min', 'agg_equipment_values_1hour',
                                  'equipment_categorical_1min', 'equipment_categorical_1hour');
