-- t237 P-app.2 ROLLBACK — restore each table's home to `gold` (pre-P-app.2 functional state).
--
-- Symmetric, catalog-only, no data at risk. Run this + revert the Go pins
-- (analytics-sync replicate/replay cursor.go, mirror-worker-go staging.go, read-api query.go)
-- back to unqualified. The stale/empty public twins are intentionally NOT recreated — they were
-- redundant shadows; restoring the live copy to `gold` returns unqualified resolution to the
-- pre-task gold-first home, which is all the old code needs.
--
-- Handles either state: post-expand (gold shim views present) or post-contract (views gone).

BEGIN;
DROP VIEW IF EXISTS gold.mirror_replay_cursor;
DROP VIEW IF EXISTS gold.user_screen_config;
ALTER TABLE app.mirror_replay_cursor SET SCHEMA gold;
ALTER TABLE app.user_screen_config   SET SCHEMA gold;
COMMIT;
