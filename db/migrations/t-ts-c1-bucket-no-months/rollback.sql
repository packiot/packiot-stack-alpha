\set ON_ERROR_STOP 1
BEGIN;
ALTER TABLE config.label_formats DROP CONSTRAINT IF EXISTS label_formats_bucket_no_months;
ALTER TABLE core.box_production_bridges DROP CONSTRAINT IF EXISTS box_production_bridges_bucket_no_months;
COMMIT;
