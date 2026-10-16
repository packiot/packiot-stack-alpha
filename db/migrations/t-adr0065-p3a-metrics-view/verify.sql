\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 categorical has max_speed', count(*) FROM information_schema.columns WHERE table_schema = 'silver' AND table_name = 'equipment_categorical_1min' AND column_name = 'max_speed';
SELECT 'V2 metrics_1min kind (r = table before 02-swap, v = view after)', relkind FROM pg_class WHERE oid = 'silver.equipment_metrics_1min'::regclass;
SELECT 'V3 rollup_refresh still writes metrics_1min (t before swap, f after)', pg_get_functiondef('silver.rollup_refresh(timestamptz,timestamptz,integer[])'::regprocedure) ~ 'INSERT INTO silver.equipment_metrics_1min';
