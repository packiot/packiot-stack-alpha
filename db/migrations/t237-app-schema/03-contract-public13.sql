-- t237 P-app.1 · CONTRACT — drop the 13 public shim views once pools recycled onto
-- the widened path (pgbouncer restarted). These are auth/i18n/config/ops tables read
-- only within packiot_analytics (no dual-DB reader resolves them against prod), so no
-- shim needs to survive. Serving/bi views over them bind app.* by OID (unaffected).
BEGIN;
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
COMMIT;
