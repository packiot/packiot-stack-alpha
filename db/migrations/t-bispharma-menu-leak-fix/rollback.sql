-- Rollback t-bispharma-menu-leak-fix (STAGING).
-- Restores role 5's permissions verbatim from the backup, then drops the backup table.

BEGIN;

DO $$
BEGIN
  IF to_regclass('ops._bkp_user_roles_perms_menuleak') IS NOT NULL
     AND EXISTS (SELECT 1 FROM ops._bkp_user_roles_perms_menuleak WHERE id_user_role = 5) THEN
    UPDATE identity.user_roles r
       SET permissions = b.permissions
      FROM ops._bkp_user_roles_perms_menuleak b
     WHERE r.id_user_role = 5 AND b.id_user_role = 5;
    DROP TABLE ops._bkp_user_roles_perms_menuleak;
  ELSE
    RAISE NOTICE 'no backup found for role 5 — nothing restored';
  END IF;
END $$;

COMMIT;
