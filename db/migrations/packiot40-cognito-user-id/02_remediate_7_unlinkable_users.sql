-- 02_remediate_7_unlinkable_users.sql
-- ============================================================================
-- #159 — resolve the 7 packiot40 users that CANNOT be Cognito-linked by email,
-- so a future Firebase-off flip does not lock them out.
--
-- TARGET DB: packiot40 (legacy customer, us-east-2) ONLY.
--
-- ⚠⚠ AUTHORED — NOT EXECUTED, AND NOT SAFE TO RUN AS-IS. ⚠⚠
--   This file DEACTIVATES production customer rows. It is gated on the user
--   CONFIRMING, per collision, which row is the live identity (STEP 0 below).
--   The proposed ids assume "keep the earliest id_user" — that MUST be verified
--   against real Firebase login activity before running, because if the row a
--   user actually authenticates as today is the one we deactivate, we lock them
--   out. Run STEP 0 (read-only) first; only then run STEP 1 / STEP 2.
--
-- BACKGROUND (hardproofed 2026-09-08, epic §8.3):
--   Cognito is email-keyed and link-on-login binds sub→row by VERIFIED email with
--   a single-row `ORDER BY id_user ASC` guard (the partial-unique index rejects a
--   multi-row link). So:
--     • A duplicate email can link ONLY its earliest-id row; the other row is
--       permanently unreachable from Cognito → 401 on Firebase-off.
--     • A NULL/empty email cannot be email-linked AT ALL.
--   These 7 rows are exactly those cases.
--
-- THE 7 ROWS:
--   Duplicate-email collisions (both enterprise 37 = Suzano):
--     jorgempv@suzano.com.br          → id_user 609 (earliest, KEEP) + 641 (stale?)
--     ottospigariol.3sv@suzano.com.br → id_user 507 (earliest, KEEP) + 612 (stale?)
--   NULL/empty-email actives (enterprise 99):
--     id_user 964, 965, 966, 967, 968
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 0 — READ-ONLY AUDIT (run first; confirm the plan before any write).
-- Confirm: which row of each pair is the LIVE Firebase identity, and what the 5
-- ent-99 no-email rows actually are (service accounts? abandoned? real people?).
-- ─────────────────────────────────────────────────────────────────────────────
-- The dup pairs — inspect id_user_firebase, email, active. The row whose
-- id_user_firebase is the one the user logs in with TODAY is the live one; that
-- MUST be the KEEP row. If the live row is NOT the earliest id, edit STEP 1's id
-- list accordingly (and the link guard's ORDER BY assumption no longer holds —
-- see the note at STEP 1).
SELECT id_user, id_enterprise, user_email, id_user_firebase, active
FROM   users
WHERE  id_user IN (609, 641, 507, 612)
ORDER  BY lower(user_email), id_user;

-- The 5 ent-99 no-email rows — inspect for any sign of a real identity.
SELECT id_user, id_enterprise, user_email, id_user_firebase, active
FROM   users
WHERE  id_user IN (964, 965, 966, 967, 968)
ORDER  BY id_user;

-- Sanity: prove these are the ONLY unlinkable actives (dup emails + NULL email).
-- Expect the dup-email query to return exactly the 2 addresses above, and the
-- NULL-email query to return exactly the 5 ids above. If more appear, STOP and
-- re-scope — the remediation lists below are then incomplete.
SELECT lower(user_email) AS email, count(*) AS active_rows
FROM   users
WHERE  active AND user_email IS NOT NULL AND user_email <> ''
GROUP  BY lower(user_email)
HAVING count(*) > 1;

SELECT id_user, id_enterprise, id_user_firebase
FROM   users
WHERE  active AND (user_email IS NULL OR user_email = '')
ORDER  BY id_user;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — DEACTIVATE the stale duplicate rows (keep the earliest id_user).
--
-- PROPOSED: deactivate 641 and 612 (keep 609 and 507). This aligns the surviving
-- row with what the link-on-login `ORDER BY id_user ASC` guard will pick anyway,
-- so after this the collision is gone and the KEEP row links cleanly.
--
-- ⚠ If STEP 0 showed the LIVE Firebase identity is 641 or 612 (NOT the earliest),
--   then EITHER: (a) re-point the login to the earliest row's id_user_firebase
--   before deactivating, OR (b) deactivate the earliest row instead and update
--   this id list — but then also confirm the link guard will pick the survivor
--   (it always picks MIN(id_user) among active id_user_cognito-NULL rows, so the
--   survivor must be the min active row). Do NOT run STEP 1 until this is settled.
--
-- Guarded: explicit id list + a row-count assertion (exactly 2 rows, both
-- currently active) so a wrong/duplicate id set aborts the whole transaction.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;

-- Assert we are about to touch EXACTLY the 2 intended, currently-active rows.
DO $$
DECLARE
  n int;
BEGIN
  SELECT count(*) INTO n
  FROM   users
  WHERE  id_user IN (641, 612) AND active;
  IF n <> 2 THEN
    RAISE EXCEPTION 'STEP 1 guard: expected 2 active rows in (641,612), found %. Aborting.', n;
  END IF;
END $$;

UPDATE users
SET    active = false
WHERE  id_user IN (641, 612)
  AND  active;   -- idempotent: never re-touch an already-deactivated row

-- Verify the survivors are still active and now collision-free.
-- (Expect 609 + 507 active, 641 + 612 inactive.)
SELECT id_user, user_email, active FROM users
WHERE  id_user IN (609, 641, 507, 612) ORDER BY id_user;

COMMIT;
-- ROLLBACK for STEP 1: UPDATE users SET active = true WHERE id_user IN (641, 612);


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — the 5 ent-99 NULL/empty-email actives. CHOOSE ONE option.
--
-- These cannot be email-linked. Leaving them active AND flipping Firebase off =
-- guaranteed lockout. So before Firebase-off, each must be either deactivated
-- (if stale/service/abandoned) or pre-provisioned in Cognito by `sub` (if a real
-- person who still needs access).
--
-- RECOMMENDATION: enterprise 99 is an internal/legacy enterprise and these rows
-- carry no email → almost certainly stale/service accounts. DEFAULT = Option A
-- (deactivate), UNLESS STEP 0 shows recent real activity, in which case give each
-- a real verified email + let JIT-migrate handle them, or use Option B.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Option A (RECOMMENDED default) — deactivate the 5 no-email rows ──────────
BEGIN;

DO $$
DECLARE
  n int;
BEGIN
  SELECT count(*) INTO n
  FROM   users
  WHERE  id_user IN (964, 965, 966, 967, 968) AND active;
  IF n <> 5 THEN
    RAISE EXCEPTION 'STEP 2A guard: expected 5 active rows in (964..968), found %. Aborting.', n;
  END IF;
END $$;

UPDATE users
SET    active = false
WHERE  id_user IN (964, 965, 966, 967, 968)
  AND  active;

SELECT id_user, id_enterprise, user_email, active FROM users
WHERE  id_user IN (964, 965, 966, 967, 968) ORDER BY id_user;

COMMIT;
-- ROLLBACK for STEP 2A: UPDATE users SET active=true WHERE id_user IN (964,965,966,967,968);

-- ── Option B (only for a row that IS a real, still-needed identity) ──────────
-- Pre-provision it in Cognito out-of-band, then bind its sub here. This is NOT a
-- pure-SQL step: first create the Cognito user (admin flow), e.g.
--   aws cognito-idp admin-create-user --user-pool-id <PROD_POOL_ID> \
--     --username <real-email-you-assign> --message-action SUPPRESS \
--     --user-attributes Name=email,Value=<email> Name=email_verified,Value=true
--   aws cognito-idp admin-set-user-password --user-pool-id <PROD_POOL_ID> \
--     --username <email> --password <temp> --permanent    # or leave for reset
-- then capture the created user's `sub` and bind it (repeat per id_user):
--
--   BEGIN;
--   UPDATE users SET id_user_cognito = '<cognito-sub-uuid>'
--   WHERE  id_user = <964..968 as applicable>
--     AND  id_user_cognito IS NULL;   -- partial-unique-safe, idempotent
--   COMMIT;
--
-- The partial-unique index (migration 01) rejects binding the same sub twice.
