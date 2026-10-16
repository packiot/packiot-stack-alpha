-- 12-users-id-cognito.sql — add users.id_user_cognito (ADR-0034 Cognito auth).
-- __SCH__ = target schema (public on packiot_analytics / F3). Idempotent.
--
-- The Cognito Bearer auth path maps a verified token's `sub` to a user row via
-- users.id_user_cognito (see auth.middleware.ts). It was added ad-hoc on prod
-- (session 95) but never migrated — so staging lacked the column, and enabling
-- EDGE_API_COGNITO_AUTH_ENABLED there 500'd with
--   "column u.id_user_cognito does not exist"
-- until it was hand-added. This migration adds it everywhere (no-op where it
-- already exists), so a fresh boot / any env has the column.

BEGIN;

DO $$
BEGIN
  IF to_regclass('__SCH__.users') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE __SCH__.users ADD COLUMN IF NOT EXISTS id_user_cognito text';
  END IF;
END $$;

COMMIT;
