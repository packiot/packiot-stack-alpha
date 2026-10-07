-- verify for t-counter-totals-float8. Read-only. label|value, expected value in the label.
\set ON_ERROR_STOP 1
SELECT 'V1 silver *_total columns as double precision: 4', count(*) FROM information_schema.columns
 WHERE table_schema='silver' AND table_name='equipment_values' AND data_type='double precision'
   AND column_name IN ('gross_production_total','net_production_total','scrap_total','process_scrap_total');
SELECT 'V2 bronze *_total columns as double precision: 4', count(*) FROM information_schema.columns
 WHERE table_schema='bronze' AND table_name='equipment_values_raw' AND data_type='double precision'
   AND column_name IN ('gross_production_total','net_production_total','scrap_total','process_scrap_total');
SELECT 'V3 old *_val columns untouched (still real): 8', count(*) FROM information_schema.columns
 WHERE (table_schema, table_name) IN (('silver','equipment_values'),('bronze','equipment_values_raw')) AND data_type='real'
   AND column_name IN ('gross_production_val','net_production_val','scrap_val','process_scrap_val');
SELECT 'V4 continuous aggregates still present: 4', count(*) FROM timescaledb_information.continuous_aggregates
 WHERE view_schema='silver' AND view_name IN ('agg_equipment_values_1min','agg_equipment_values_1hour','equipment_categorical_1min','equipment_categorical_1hour');
SELECT 'V5 float8 holds 297922467 exactly / float4 does not: t|f', 297922467::double precision::bigint = 297922467, 297922467::real::bigint = 297922467;
