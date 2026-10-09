-- t-po-availability-exclusions — PO grain no-data / out-of-service columns (2026-10-01)
-- stream-engine computeAvailabilitySQL (PO_AVAILABILITY_ENABLED) now leaves
-- out-of-service windows and PLC no-data time out of a PO's available_time
-- (AVAILABILITY_EXCLUSIONS_ENABLED) and records them here. Plain table → the adds
-- are metadata-only. Short lock_timeout: the PO compute loop holds row locks on
-- this table every few minutes; if it times out, re-run (idempotent).
-- Apply BEFORE the stream-engine that writes the columns.
SET lock_timeout = '3s';
ALTER TABLE gold.production_orders_runtime
    ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.production_orders_runtime.no_data_time IS 'Seconds of the run the line''s PLC could not be read (no data): excluded from available_time.';
COMMENT ON COLUMN gold.production_orders_runtime.out_of_service_time IS 'Seconds of the run inside an out-of-service window (config.equipment_out_of_service): excluded from available_time.';
