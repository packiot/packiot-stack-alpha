-- t241 · APP SPLIT · CONTRACT — drop the 16 `app.*` shim views and the now-empty
-- `app` schema. RUN ONLY AFTER the three redeployed services (stream-engine,
-- analytics-sync, read-api — PR #1171) are live and hardproofed writing/reading their
-- new schemas (config/ops/auth). Premature drop is UNSAFE: analytics-sync + read-api
-- self-provision their tables at startup, so an old-binary restart would re-run
-- CREATE SCHEMA/TABLE IF NOT EXISTS app.<t> and re-spawn an EMPTY base table shadowing
-- the real one. GATE before running: `SELECT ... FROM pg_stat_activity` shows no old
-- image, and a fresh `app.mirror_replay_cursor`/`app.user_screen_config`/`app.label_formats`
-- write test lands in ops/auth/config (through the shim) with the NEW binaries deployed.
BEGIN;
SET LOCAL lock_timeout = '5s';

DROP VIEW IF EXISTS app.users, app.user_roles, app.user_screen_config, app.user_logs,
  app.translations, app.tenant_translations, app.language_packs, app.pages,
  app.dashboard_config, app.labels, app.label_formats, app.idempotency_keys,
  app.function_execution_log, app.capture_observations, app.mirror_replay_cursor,
  app.mirror_replay_dlq;

-- RESTRICT (default) asserts nothing else remains bound to `app`.
DROP SCHEMA app;

COMMIT;
