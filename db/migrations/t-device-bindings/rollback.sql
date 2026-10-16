-- rollback for t-device-bindings. Safe while nothing reads core.device_bindings (true until ADR-0061 P2 ships).
-- After P2 the decoder resolves through this table: switch every client back to topic_routing first.
-- NOTE: the backfilled keys are random. Dropping the table discards them; a re-run of 01-up.sql issues NEW keys,
-- so any descriptor that already received keys must be regenerated.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP TABLE IF EXISTS core.device_bindings;
DROP INDEX IF EXISTS core.equipments_id_equipment_id_enterprise_uq;
COMMIT;
