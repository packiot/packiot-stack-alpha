-- t247 · ROLLBACK — revert identity→auth (drop compat views first). Revert service code too.
BEGIN;
DROP VIEW IF EXISTS auth.users, auth.user_roles, auth.user_screen_config, auth.user_logs;
DROP SCHEMA IF EXISTS auth;
ALTER SCHEMA identity RENAME TO auth;
COMMIT;
ALTER DATABASE packiot_analytics SET search_path = "$user", gold, silver, bronze, auth, config, ops, serving, customer_reports, core, public;
