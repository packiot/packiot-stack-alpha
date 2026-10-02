-- Set AVAILABILITY_EXCLUSIONS_ENABLED=false (or roll back stream-engine) first.
ALTER TABLE gold.production_orders_runtime DROP COLUMN IF EXISTS no_data_time, DROP COLUMN IF EXISTS out_of_service_time;
