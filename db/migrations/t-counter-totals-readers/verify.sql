-- verify for t-counter-totals-readers (+ t-data-invariants-v7). Read-only. Every line prints label|value;
-- the expected value is in the label.
\set ON_ERROR_STOP 1

SELECT 'V1 bi.live_status *_total columns, double precision: 3',
       count(*) FROM information_schema.columns
        WHERE table_schema = 'bi' AND table_name = 'live_status' AND column_name ~ '_total$' AND data_type = 'double precision';
SELECT 'V2 silver.equipment_values_labeled *_total columns, double precision: 4',
       count(*) FROM information_schema.columns
        WHERE table_schema = 'silver' AND table_name = 'equipment_values_labeled' AND column_name ~ '_total$' AND data_type = 'double precision';
SELECT 'V3 old *_val view columns kept as real (3 + 4): 7',
       count(*) FROM information_schema.columns
        WHERE (table_schema, table_name) IN (('bi','live_status'), ('silver','equipment_values_labeled'))
          AND column_name ~ '_val$' AND data_type = 'real';
SELECT 'V4 grants unchanged (readapi_ro and superset_ro SELECT on both views): 4',
       count(*) FROM information_schema.role_table_grants
        WHERE (table_schema, table_name) IN (('bi','live_status'), ('silver','equipment_values_labeled'))
          AND grantee IN ('readapi_ro', 'superset_ro') AND privilege_type = 'SELECT';
SELECT 'V5 invariants proc reads *_total (v7): t',
       pg_get_functiondef('ops.job_data_invariants'::regproc) ~ 'coalesce\(v\.net_production_total, v\.net_production_val\)';
SELECT 'V6 invariants proc has C7 (v6 included): t',
       pg_get_functiondef('ops.job_data_invariants'::regproc) ~ 'C7_po_started_without_window';
-- after stream-engine F1b is deployed: fresh counter rows carry an exact total equal to the float4 value
-- within float4 spacing (|total - val| <= 32 at ~3e8)
SELECT 'V7 counter rows in the last 10 min with *_total written (after F1b deploy: > 0)',
       count(*) FILTER (WHERE coalesce(net_production_total, gross_production_total, scrap_total) IS NOT NULL),
       count(*) FILTER (WHERE coalesce(net_production_val, gross_production_val, scrap_val) IS NOT NULL)
  FROM silver.equipment_values WHERE ts_value > now() - interval '10 minutes';
SELECT 'V8 dual-written rows where total and val disagree beyond float4 spacing: 0',
       count(*) FROM silver.equipment_values
        WHERE ts_value > now() - interval '10 minutes'
          AND (abs(net_production_total - net_production_val) > greatest(1, abs(net_production_total) * 2^(-23))
            OR abs(gross_production_total - gross_production_val) > greatest(1, abs(gross_production_total) * 2^(-23))
            OR abs(scrap_total - scrap_val) > greatest(1, abs(scrap_total) * 2^(-23)));
SELECT 'V9 bronze rows in the last 10 min with *_total written (after F1b deploy, if BRONZE_RAW_APPEND: > 0)',
       count(*) FILTER (WHERE coalesce(net_production_total, gross_production_total, scrap_total) IS NOT NULL)
  FROM bronze.equipment_values_raw WHERE ts_value > now() - interval '10 minutes';
SELECT 'V10 live_status rows (sanity: > 0)', count(*) FROM bi.live_status;
