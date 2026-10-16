-- Rollback of t-replicate-manual-events. Set RECONCILE_MANUAL_EVENTS_ENABLED=false
-- and redeploy the legacy-replicator FIRST (it recreates the table on start).
-- Mirrored rows stay in silver.equipment_events_man; only provenance is lost.
DROP TABLE IF EXISTS ops.legacy_manual_event_link;
