-- Back to the identity fill everywhere. Drop the column only after the
-- stream-engine that reads it has been rolled back too.
BEGIN;
UPDATE core.equipments SET fill_missing_meter = NULL WHERE fill_missing_meter IS NOT NULL;
-- ALTER TABLE core.equipments DROP COLUMN fill_missing_meter;
COMMIT;
