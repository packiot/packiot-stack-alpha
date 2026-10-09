-- rollback for t-adr0061-p3d-bindings-backfill: intentionally NONE. Minted keys are identities that may already be
-- stamped into descriptors / pushed to boxes; deleting them would orphan those. To retire one equipment's key,
-- deactivate the equipment through edge-api (the binding is deactivated with it and kept for reactivation).
SELECT 'no-op rollback (see comment)';
