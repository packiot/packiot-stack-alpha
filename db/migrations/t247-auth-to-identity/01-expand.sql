-- t247 · rename the `auth` schema → `identity` (EXPAND). The `auth` name misleads —
-- the schema holds the app's IDENTITY + authorization (users/roles/permissions/profile
-- keyed to Cognito's id_user_cognito), NOT authentication (Cognito owns credentials).
-- `identity` is honest and avoids `iam` (which collides with AWS IAM — a different layer:
-- IAM=cloud-resource access, Cognito=authN, this=domain authZ). See ADR-0056.
-- Renaming the schema moves its 4 tables + owned objects by OID; serving.v_entities_per_user_role
-- + v_menu_per_user_role follow by OID. `auth.*` compat views bridge the deploy window for the
-- qualified consumers (read-api user_screen_config, stream-engine route.auth→user_logs) until they
-- redeploy; bare edge-api reads resolve via the widened search_path. Dropped in 02-contract.
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER SCHEMA auth RENAME TO identity;
CREATE SCHEMA auth;
CREATE VIEW auth.users              AS SELECT * FROM identity.users;
CREATE VIEW auth.user_roles         AS SELECT * FROM identity.user_roles;
CREATE VIEW auth.user_screen_config AS SELECT * FROM identity.user_screen_config;
CREATE VIEW auth.user_logs          AS SELECT * FROM identity.user_logs;
COMMENT ON SCHEMA identity IS 'Application IDENTITY + authorization (authZ) — the app''s user records keyed to Cognito (id_user_cognito): users, user_roles (permissions/super_user), user_screen_config, user_logs (audit). NOT authentication — Cognito holds credentials; NOT AWS IAM (cloud-resource access). See ADR-0056.';
COMMIT;
ALTER DATABASE packiot_analytics SET search_path = "$user", gold, silver, bronze, identity, auth, config, ops, serving, customer_reports, core, public;
