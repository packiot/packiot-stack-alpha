-- 01_add_id_user_cognito.down.sql
-- ============================================================================
-- ROLLBACK for 01_add_id_user_cognito.up.sql — LEGACY `packiot40` only.
--
-- ⚠ AUTHORED — NOT EXECUTED. Only meaningful BEFORE any user has been linked.
--   Once id_user_cognito rows are populated (post-cutover) this DROP throws away
--   the Cognito→tenant bindings and forces every migrated user back onto the
--   Firebase leg — safe ONLY while Firebase is still dual-accepted, never after
--   the Firebase-off flip.
--
-- ⚠ TRANSACTION NOTE: DROP INDEX CONCURRENTLY also cannot run inside a
--   transaction block. Run without --single-transaction.
-- ============================================================================

-- Drop the partial unique index first (CONCURRENTLY = no long lock). Covers the
-- case where a prior CREATE INDEX CONCURRENTLY was interrupted and left an
-- INVALID index of the same name.
DROP INDEX CONCURRENTLY IF EXISTS users_id_user_cognito_key;

-- Then drop the column.
ALTER TABLE users
    DROP COLUMN IF EXISTS id_user_cognito;
