-- 01_drop_operator_pw_hash.up.sql  (#159 — retire the operator-password bcrypt slice)
--
-- Drops users.operator_pw_hash. The cloud /session login has been Cognito-only
-- since #156/#243 and NOTHING verifies this hash (the only bcrypt.compare was a
-- unit test). The architect decided (2026-09-06) to commit to cached-token +
-- local-JWKS as the sole on-prem offline auth, superseding the ADR-0054 bcrypt
-- fresh-offline-login fallback — so the column is now truly dead.
--
-- ORDERING (MANDATORY): run ONLY AFTER the edge-api writer-removal is DEPLOYED
-- (set-operator-password usecase gone; create-user / create-cognito-user no longer
-- INSERT/UPDATE the column; session-dao no longer SELECTs it). Otherwise a live
-- INSERT/UPDATE referencing the column errors 42703. Verify with:
--   grep -rn operator_pw_hash edge-api/src  → 0 hits.
--
-- Reversible: see 01_drop_operator_pw_hash.down.sql (re-adds the nullable column;
-- historical hashes are NOT restored — they were write-only and unverifiable).
-- Idempotent via IF EXISTS. Run against packiot_analytics (and packiot if F1 still
-- carries it — check first).

\set ON_ERROR_STOP on
BEGIN;
\echo '### BEFORE: does the column exist + is anything non-null? ###'
SELECT count(*) FILTER (WHERE operator_pw_hash IS NOT NULL) AS non_null_hashes,
       count(*) AS total_users
FROM users;

ALTER TABLE users DROP COLUMN IF EXISTS operator_pw_hash;

\echo '### AFTER: column gone? (expect 0) ###'
SELECT count(*) AS operator_pw_hash_cols
FROM information_schema.columns
WHERE table_name='users' AND column_name='operator_pw_hash';
COMMIT;
