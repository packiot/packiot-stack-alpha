-- Retention profile: STAGING-CAPPED (cost/storage cap — everything 3 months).
-- Apply ONLY after production is promoted and serving (see
-- docs/plans/unified-hot-cold-serving-grain-tiered-retention.md §7). DESTRUCTIVE on
-- the next purge run: deletes staging analytics history older than 3 months,
-- including business records (POs) — staging is a rehearsal env, prod keeps them.
-- The staging HISTORIAN cap is separate: scripts/historian-prune-by-data-age.sh
-- (S3 lifecycle expires by OBJECT age, not data age — it cannot implement this cap).
BEGIN;
UPDATE ops.retention_policy SET keep = interval '3 months', updated_at = now()
 WHERE relation <> 'ops.retention_run';
CALL ops.apply_retention();
COMMIT;
-- FK-safe order is handled by purge_order (box/po_box_counter → runtime → POs).
-- Verify: SELECT * FROM ops.retention_drift;  -- want 0 rows
--         SELECT * FROM ops.retention_run ORDER BY ran_at DESC LIMIT 40;  -- no errors after next purge
