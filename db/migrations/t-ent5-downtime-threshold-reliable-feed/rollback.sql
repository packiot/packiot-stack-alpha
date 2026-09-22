-- rollback t-ent5-downtime-threshold-reliable-feed
-- Restores the previous 1800s threshold for ent5.
BEGIN;
UPDATE core.equipments SET stop_threshold_time = 1800 WHERE id_enterprise = 5;
COMMIT;
