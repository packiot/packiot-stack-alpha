-- rollback t-ent5-counters-only-status-and-threshold
--
-- Reverts the ent5 data changes. NOTE: the functional off-switch for the live
-- deriver is CPAC_EVENT_LIVE_ENTERPRISES="" in compose (stops minting); this only
-- undoes the equipment data. Restores status_type to NULL and stop_threshold_time
-- to the 300s config default.

BEGIN;

UPDATE core.equipments SET status_type = NULL WHERE id_enterprise = 5;
UPDATE core.equipments SET stop_threshold_time = 300 WHERE id_enterprise = 5;

COMMIT;
