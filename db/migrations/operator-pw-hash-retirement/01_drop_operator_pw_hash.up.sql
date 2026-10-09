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
--
-- APPLIED LOG:
--   - packiot_analytics (10.10.10.89): column already ABSENT (#219 confirmed).
--   - packiot (legacy, Hasura-fronted, 10.10.10.89): APPLIED 2026-09-08 (#220).
--     Dropped public.users.operator_pw_hash — was text/nullable, 5 non-null dead
--     bcrypt hashes (id_user 2,4,120,2000002,2000005), no view dependency.
--     HASURA GATE (see HASURA-GATE.md): the string 'operator_pw_hash' appears
--     NOWHERE in hdb_metadata (14868-char blob), the users select-permission
--     (role 'user') already projected it out, and no Hasura HTTP endpoint fronts
--     the staging plane — so no untrack step was required and the drop introduced
--     zero metadata inconsistency. back4-api / edge-api / read-api have no live
--     reader (edge-api /session is Cognito-only; read-api projects it out).

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
