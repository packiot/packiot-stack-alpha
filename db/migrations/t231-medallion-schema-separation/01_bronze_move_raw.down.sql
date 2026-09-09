-- t231 · PHASE 1 (BRONZE) — reversal. Instant, no data at risk (0 chunks).
BEGIN;
ALTER TABLE bronze.equipment_values_raw SET SCHEMA public;
ALTER TABLE bronze.equipment_events_raw SET SCHEMA public;
-- Leave the empty `bronze` schema in place if PHASE 2 search_path still lists it;
-- drop only when fully rolling back the medallion split:
-- DROP SCHEMA IF EXISTS bronze;
COMMIT;
