-- t247 · CONTRACT — drop the auth.* compat views + the auth schema, AFTER read-api +
-- stream-engine redeploy to identity.* (PR #1182). Narrow the search_path (drop `auth`).
BEGIN;
DROP VIEW IF EXISTS auth.users, auth.user_roles, auth.user_screen_config, auth.user_logs;
DROP SCHEMA auth;
COMMIT;
ALTER DATABASE packiot_analytics SET search_path = "$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public;
