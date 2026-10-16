-- t237 P-app.1 · ROLLBACK — symmetric reverse (catalog-only). Safe whether or not
-- the contract already dropped the shims. (Does NOT touch the P-app.2 gold→app trio.)
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP VIEW IF EXISTS public.users;
DROP VIEW IF EXISTS public.user_roles;
DROP VIEW IF EXISTS public.user_logs;
DROP VIEW IF EXISTS public.translations;
DROP VIEW IF EXISTS public.tenant_translations;
DROP VIEW IF EXISTS public.language_packs;
DROP VIEW IF EXISTS public.pages;
DROP VIEW IF EXISTS public.dashboard_config;
DROP VIEW IF EXISTS public.labels;
DROP VIEW IF EXISTS public.label_formats;
DROP VIEW IF EXISTS public.idempotency_keys;
DROP VIEW IF EXISTS public.function_execution_log;
DROP VIEW IF EXISTS public.capture_observations;

ALTER TABLE app.users                  SET SCHEMA public;
ALTER TABLE app.user_roles             SET SCHEMA public;
ALTER TABLE app.user_logs              SET SCHEMA public;
ALTER TABLE app.translations           SET SCHEMA public;
ALTER TABLE app.tenant_translations    SET SCHEMA public;
ALTER TABLE app.language_packs         SET SCHEMA public;
ALTER TABLE app.pages                  SET SCHEMA public;
ALTER TABLE app.dashboard_config       SET SCHEMA public;
ALTER TABLE app.labels                 SET SCHEMA public;
ALTER TABLE app.label_formats          SET SCHEMA public;
ALTER TABLE app.idempotency_keys       SET SCHEMA public;
ALTER TABLE app.function_execution_log SET SCHEMA public;
ALTER TABLE app.capture_observations   SET SCHEMA public;
COMMIT;

-- Narrow path back (keep barcode from P-barcode; drop app):
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, public;
-- Then restart stack-pgbouncer-1.
