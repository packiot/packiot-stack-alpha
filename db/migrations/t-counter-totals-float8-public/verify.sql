\set ON_ERROR_STOP 1
SELECT 'V1 public.equipment_values *_total float8 columns: 4', count(*) FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'equipment_values' AND column_name ~ '_total$' AND data_type = 'double precision';
SELECT 'V2 public.equipment_values_raw *_total columns (4, or 0 if the table is absent)', count(*) FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'equipment_values_raw' AND column_name ~ '_total$' AND data_type = 'double precision';
SELECT 'V3 float8 holds 297922487 exactly / float4 does not: t|f', 297922487::float8 = 297922487, 297922487::real::float8 = 297922487;
SELECT 'V4 after COUNTER_TOTALS_PUBLIC=true: rows with *_total in the last 10 min (> 0)',
       count(*) FILTER (WHERE coalesce(net_production_total, gross_production_total, scrap_total) IS NOT NULL)
  FROM public.equipment_values WHERE ts_value > now() - interval '10 minutes';
