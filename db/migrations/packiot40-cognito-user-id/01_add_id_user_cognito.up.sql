-- 01_add_id_user_cognito.up.sql
-- ============================================================================
-- #159 / ADR-0034 — add the Cognito per-user tenant key to the LEGACY customer
-- DB `packiot40` (18.220.223.110, us-east-2), mirroring the new-stack migration
-- edge-node-red/db/32-cognito-user-id.sql.
--
-- TARGET DB: packiot40 ONLY (the legacy customer plane served by back4-api +
--            primary-api + edge-api-prod). This is NOT for the new-stack
--            `packiot`/`packiot_analytics` DBs — those already have the column.
--
-- ⚠ AUTHORED — NOT EXECUTED. This file is a reviewable artifact. Running it is a
--   prod-customer-DB write gated on explicit user go (epic Phase 0.3). Do not run
--   it before the front4-prod cutover is scheduled — it is harmless to apply
--   early (additive + nullable) but it is codified here as the schema
--   precondition for the backend OR-resolver + link-on-login write.
--
-- WHY
-- ───
-- back4-api + primary-api must resolve a verified Cognito `sub` → id_enterprise
-- the SAME server-side way they resolve a Firebase uid, so `users` needs a column
-- holding each user's Cognito subject ALONGSIDE id_user_firebase. During the
-- dual-accept window a single row may carry BOTH ids; the unified lookup
-- (WHERE id_user_cognito = $1 OR id_user_firebase = $1) matches EITHER, so the
-- tenant is fenced identically whichever token the browser sends.
--
-- SAFETY: additive + nullable → ZERO impact on the running Firebase path. No row
-- is populated by this migration; linking happens later, on login.
--
-- ⚠ TRANSACTION NOTE: `CREATE INDEX CONCURRENTLY` CANNOT run inside a
--   transaction block (it manages its own locks/commits). Run this file with
--   psql WITHOUT wrapping it in BEGIN/COMMIT (psql runs each statement in its own
--   implicit transaction by default — do NOT pass -1/--single-transaction).
--   If CONCURRENTLY is interrupted it can leave an INVALID index; the reindex/
--   drop path is in 01_add_id_user_cognito.down.sql.
-- ============================================================================

-- Additive, idempotent column.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS id_user_cognito varchar(255);

-- Mirror id_user_firebase's UNIQUE guarantee — the "at most one row" property
-- the resolver's OR-match relies on for tenant safety — as a PARTIAL unique
-- index: the column is NULL for every not-yet-migrated user (many rows), and
-- uniqueness is enforced only across populated subjects. CONCURRENTLY so the
-- build takes no long ACCESS EXCLUSIVE lock on the live `users` table.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS users_id_user_cognito_key
    ON users (id_user_cognito)
    WHERE id_user_cognito IS NOT NULL;
