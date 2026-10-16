-- t-ts-c1-bucket-no-months — ADR-0063 Phase C1: report buckets must be date_bin-compatible (2026-10-15).
-- The box reports now bucket with date_bin(bucket, ts, '2000-01-03') instead of TimescaleDB's
-- time_bucket (identical for every interval without months — proven 0 mismatches for 1 min..7 days).
-- date_bin rejects month/year intervals at run time, so forbid them where they are configured.
-- Staging 2026-10-15: label_formats {NULL, 00:00:01}, box_production_bridges {00:01:00}: 0 violations.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
ALTER TABLE config.label_formats DROP CONSTRAINT IF EXISTS label_formats_bucket_no_months;
ALTER TABLE config.label_formats ADD CONSTRAINT label_formats_bucket_no_months
  CHECK (bucket IS NULL OR (date_part('month', bucket) = 0 AND date_part('year', bucket) = 0 AND bucket > interval '0')) NOT VALID;
ALTER TABLE config.label_formats VALIDATE CONSTRAINT label_formats_bucket_no_months;
ALTER TABLE core.box_production_bridges DROP CONSTRAINT IF EXISTS box_production_bridges_bucket_no_months;
ALTER TABLE core.box_production_bridges ADD CONSTRAINT box_production_bridges_bucket_no_months
  CHECK (bucket IS NULL OR (date_part('month', bucket) = 0 AND date_part('year', bucket) = 0 AND bucket > interval '0')) NOT VALID;
ALTER TABLE core.box_production_bridges VALIDATE CONSTRAINT box_production_bridges_bucket_no_months;
COMMIT;
