-- t-bispharma-operator-readiness — make Bispharma (enterprise 5) operator-ready on STAGING.
--
-- WHY (GAP-7 operator-readiness audit)
-- ────────────────────────────────────
-- Bispharma-Staging (id_enterprise=5, nm_enterprise "Bispharma-Staging") was fully
-- onboarded on the entity side (23 lines scoped by role `operator-bispharma-staging`,
-- id_user_role=5) but was NOT loginable and could NOT write:
--
--   1. `identity.users` had ZERO rows for id_enterprise=5. edge-api resolves a caller's
--      tenant with `SELECT id_enterprise, user_roles FROM users WHERE id_user_cognito=$1`
--      (src/data/DAO/auth-middleware/auth-user-dao.ts::resolveEnterpriseByUid). No row ⇒
--      every Bispharma login resolves null ⇒ AuthMiddleware throws 401 (hard blocker).
--
--   2. Role 5's permissions.desktop.screen[*].write were ALL `false`, so even a logged-in
--      operator got a read-only UI. front4 gates PO editing on the code-6 write flag
--      (src/pages/ProductionOrders/index.jsx:32-34 — canEditProductionOrders =
--      permissions.desktop.screen[code==6].write); Downtimes=code 3, Settings=code 24.
--
-- This migration replicates the CPACK (enterprise 3) reference pattern: CPACK has a
-- service-account operator row in identity.users + a scoped operator role.
--
-- TWO USER-APPROVED ACTIONS
-- ─────────────────────────
--   A. Seed a clearly-labelled PLACEHOLDER operator SERVICE ACCOUNT for enterprise 5 so the
--      login + PO flow is provable end-to-end.
--   B. Grant role 5 (operator-bispharma-staging) FULL WRITE on every operator screen.
--
-- ┌──────────────────────────────────────────────────────────────────────────────────────┐
-- │ STAGING ONLY. DO NOT forward-port this file to prod verbatim.                          │
-- │ The Cognito user + users row are a PLACEHOLDER (operator-bispharma-staging@packiot.com,│
-- │ obviously not a real person). For prod, csadmin onboarding OWNS this: the CS-Admin      │
-- │ surface POST /api/cognito-users (edge-api) creates the Cognito identity AND the         │
-- │ identity.users row with the optional idUserRole stamp in one call                       │
-- │ (csadmin/src/api/users-admin.ts). Onboard REAL operators there, then flip the role      │
-- │ write flags. #159 retired the operator_pw_hash/bcrypt kiosk login — auth is             │
-- │ Cognito-only, so there is no password column to seed.                                   │
-- └──────────────────────────────────────────────────────────────────────────────────────┘
--
-- NOTE (out-of-band, cannot live in SQL): a matching Cognito user was created in the
-- staging pool us-east-1_0T9t1sTwt for the placeholder email with a labelled temp password:
--   aws cognito-idp admin-create-user   --user-pool-id us-east-1_0T9t1sTwt \
--       --username operator-bispharma-staging@packiot.com --message-action SUPPRESS \
--       --user-attributes Name=email,Value=operator-bispharma-staging@packiot.com \
--                         Name=email_verified,Value=true
--   aws cognito-idp admin-set-user-password ... --password '<labelled-temp>' --permanent
-- edge-api's link-on-login self-heal (ADR-0034) then binds users.id_user_cognito to the
-- token `sub` by verified email on the first login — so this seed leaves id_user_cognito
-- NULL on purpose.

BEGIN;

-- ── Action A: placeholder operator service account (idempotent by email) ─────────────────
INSERT INTO identity.users
  (user_email, user_name, id_enterprise, user_roles, internal_user, active, id_user_cognito)
SELECT
  'operator-bispharma-staging@packiot.com',
  'PLACEHOLDER Bispharma Operator (staging service acct - NOT a real person)',
  5, 5, true, true, NULL
WHERE NOT EXISTS (
  SELECT 1 FROM identity.users WHERE user_email = 'operator-bispharma-staging@packiot.com'
);

-- ── Action B: role 5 → FULL WRITE on every screen (preserves screen codes + line scope) ──
-- Backup the pre-mutation permissions so rollback can restore verbatim.
CREATE TABLE IF NOT EXISTS ops._bkp_user_roles_perms_bispharma AS
  SELECT id_user_role, permissions, now() AS backed_up_at
  FROM identity.user_roles WHERE id_user_role = 5;

UPDATE identity.user_roles
SET permissions = jsonb_set(
      permissions, '{desktop,screen}',
      (SELECT jsonb_agg(jsonb_set(elem, '{write}', 'true'::jsonb) ORDER BY (elem->>'code')::int)
         FROM jsonb_array_elements(permissions->'desktop'->'screen') elem)
    )
WHERE id_user_role = 5;

COMMIT;

-- ── Verification (run after) ─────────────────────────────────────────────────────────────
-- SELECT id_enterprise, user_roles, active FROM identity.users
--   WHERE user_email='operator-bispharma-staging@packiot.com';                 -- 5 | 5 | t
-- SELECT count(*) FROM identity.user_roles, jsonb_array_elements(permissions->'desktop'->'screen') s
--   WHERE id_user_role=5 AND (s->>'write')::bool = false;                      -- 0
