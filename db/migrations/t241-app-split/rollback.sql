-- t241 · APP SPLIT · ROLLBACK — reverse expand+contract: recreate `app`, drop the
-- shim views (if the contract already ran they don't exist — IF EXISTS), move the 16
-- tables back to `app`, restore the pre-split search_path. Catalog-only; symmetric.
-- NOTE: if code was already redeployed to auth/config/ops, revert those deploys FIRST.
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE SCHEMA IF NOT EXISTS app;

DROP VIEW IF EXISTS app.users, app.user_roles, app.user_screen_config, app.user_logs,
  app.translations, app.tenant_translations, app.language_packs, app.pages,
  app.dashboard_config, app.labels, app.label_formats, app.idempotency_keys,
  app.function_execution_log, app.capture_observations, app.mirror_replay_cursor,
  app.mirror_replay_dlq;

ALTER TABLE auth.users              SET SCHEMA app;
ALTER TABLE auth.user_roles         SET SCHEMA app;
ALTER TABLE auth.user_screen_config SET SCHEMA app;
ALTER TABLE auth.user_logs          SET SCHEMA app;
ALTER TABLE config.translations        SET SCHEMA app;
ALTER TABLE config.tenant_translations SET SCHEMA app;
ALTER TABLE config.language_packs      SET SCHEMA app;
ALTER TABLE config.pages               SET SCHEMA app;
ALTER TABLE config.dashboard_config    SET SCHEMA app;
ALTER TABLE config.labels              SET SCHEMA app;
ALTER TABLE config.label_formats       SET SCHEMA app;
ALTER TABLE ops.idempotency_keys       SET SCHEMA app;
ALTER TABLE ops.function_execution_log SET SCHEMA app;
ALTER TABLE ops.capture_observations   SET SCHEMA app;
ALTER TABLE ops.mirror_replay_cursor   SET SCHEMA app;
ALTER TABLE ops.mirror_replay_dlq      SET SCHEMA app;

COMMIT;

ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, app, serving, customer_reports, core, public;
-- Optional once confirmed empty: DROP SCHEMA auth; DROP SCHEMA config; DROP SCHEMA ops;
