-- rollback for t-sandbox-grace-hold. Deploy the replicator with SANDBOX_HOLD_ENABLED unset
-- (or false) FIRST — with the view gone a hold-enabled replicator fails open (replicates).
DROP FUNCTION IF EXISTS ops.sandbox_heal_end(integer, boolean, text);
DROP FUNCTION IF EXISTS ops.sandbox_heal_begin(integer, boolean);
DROP FUNCTION IF EXISTS ops.sandbox_held(integer);
DROP VIEW IF EXISTS ops.sandbox_hold_status;
DROP FUNCTION IF EXISTS ops.sandbox_is_change(text);
DROP TABLE IF EXISTS ops.sandbox_state;
DROP INDEX IF EXISTS identity.user_logs_enterprise_ts_idx;
