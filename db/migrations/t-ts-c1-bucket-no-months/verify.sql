\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 constraints present and validated: 2', count(*) FROM pg_constraint
 WHERE conname IN ('label_formats_bucket_no_months', 'box_production_bridges_bucket_no_months') AND convalidated;
