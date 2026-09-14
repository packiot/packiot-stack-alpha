-- Rollback t-bispharma-operator-readiness (STAGING).
--
-- Reverses both actions:
--   B. Restore role 5's permissions verbatim from the backup taken by 01-seed.sql, then
--      drop the backup table. (Falls back to flipping every screen write→false if the
--      backup is absent — the original state was all-false.)
--   A. Delete the placeholder operator service-account row.
--
-- Out-of-band (not SQL): disable/delete the placeholder Cognito user if desired —
--   aws cognito-idp admin-delete-user --user-pool-id us-east-1_0T9t1sTwt \
--       --username operator-bispharma-staging@packiot.com

BEGIN;

-- B. Restore role 5 permissions from backup (verbatim), else force all screen writes false.
DO $$
BEGIN
  IF to_regclass('ops._bkp_user_roles_perms_bispharma') IS NOT NULL
     AND EXISTS (SELECT 1 FROM ops._bkp_user_roles_perms_bispharma WHERE id_user_role = 5) THEN
    UPDATE identity.user_roles r
       SET permissions = b.permissions
      FROM ops._bkp_user_roles_perms_bispharma b
     WHERE r.id_user_role = 5 AND b.id_user_role = 5;
    DROP TABLE ops._bkp_user_roles_perms_bispharma;
  ELSE
    UPDATE identity.user_roles
       SET permissions = jsonb_set(
             permissions, '{desktop,screen}',
             (SELECT jsonb_agg(jsonb_set(elem, '{write}', 'false'::jsonb) ORDER BY (elem->>'code')::int)
                FROM jsonb_array_elements(permissions->'desktop'->'screen') elem))
     WHERE id_user_role = 5;
  END IF;
END $$;

-- A. Remove the placeholder service account.
DELETE FROM identity.users WHERE user_email = 'operator-bispharma-staging@packiot.com';

COMMIT;
