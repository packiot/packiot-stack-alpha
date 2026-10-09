-- t241 · APP SPLIT · EXPAND — reverse the P-app junk-drawer; split `app`'s 16 tables
-- into three cohesive schemas by concern (task #241 §12.2), each bridged by an
-- auto-updatable `app.<t>` shim view so BOTH the old qualified `app.<t>` refs (stream-
-- engine AppSchema, analytics-sync, read-api) AND bare writers on not-yet-recycled
-- pools keep resolving through the window — zero-downtime, deploy-free this phase.
--
--   auth   (identity)      : users, user_roles, user_screen_config, user_logs
--   config (i18n / labels) : translations, tenant_translations, language_packs, pages,
--                            dashboard_config, labels, label_formats
--   ops    (plumbing)      : idempotency_keys, function_execution_log, capture_observations,
--                            mirror_replay_cursor, mirror_replay_dlq
--
-- Catalog-only (no data copied); owned sequences, indexes, FKs, triggers, and dependent
-- serving/bi views all follow each table by OID. ON CONFLICT is shim-SAFE: every arbiter
-- matches a real PK/UNIQUE (verified — idempotency_keys(idempotency_key)=pkey,
-- translations/tenant_translations col-lists=pkey), and an auto-updatable view passes
-- INSERT…ON CONFLICT through to the base (proven in P-core; the scrap_targets failure
-- there was a WRONG arbiter, not a view limitation).
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS config;
CREATE SCHEMA IF NOT EXISTS ops;

-- ── auth (4) ─────────────────────────────────────────────────────────────────
ALTER TABLE app.users              SET SCHEMA auth;
ALTER TABLE app.user_roles         SET SCHEMA auth;
ALTER TABLE app.user_screen_config SET SCHEMA auth;
ALTER TABLE app.user_logs          SET SCHEMA auth;
-- ── config (7) ───────────────────────────────────────────────────────────────
ALTER TABLE app.translations        SET SCHEMA config;
ALTER TABLE app.tenant_translations SET SCHEMA config;
ALTER TABLE app.language_packs      SET SCHEMA config;
ALTER TABLE app.pages               SET SCHEMA config;
ALTER TABLE app.dashboard_config    SET SCHEMA config;
ALTER TABLE app.labels              SET SCHEMA config;
ALTER TABLE app.label_formats       SET SCHEMA config;
-- ── ops (5) ──────────────────────────────────────────────────────────────────
ALTER TABLE app.idempotency_keys       SET SCHEMA ops;
ALTER TABLE app.function_execution_log SET SCHEMA ops;
ALTER TABLE app.capture_observations   SET SCHEMA ops;
ALTER TABLE app.mirror_replay_cursor   SET SCHEMA ops;
ALTER TABLE app.mirror_replay_dlq      SET SCHEMA ops;

-- ── app.* shim views (dropped in 03-contract after the 3 services redeploy) ────
CREATE VIEW app.users                  AS SELECT * FROM auth.users;
CREATE VIEW app.user_roles             AS SELECT * FROM auth.user_roles;
CREATE VIEW app.user_screen_config     AS SELECT * FROM auth.user_screen_config;
CREATE VIEW app.user_logs              AS SELECT * FROM auth.user_logs;
CREATE VIEW app.translations           AS SELECT * FROM config.translations;
CREATE VIEW app.tenant_translations    AS SELECT * FROM config.tenant_translations;
CREATE VIEW app.language_packs         AS SELECT * FROM config.language_packs;
CREATE VIEW app.pages                  AS SELECT * FROM config.pages;
CREATE VIEW app.dashboard_config       AS SELECT * FROM config.dashboard_config;
CREATE VIEW app.labels                 AS SELECT * FROM config.labels;
CREATE VIEW app.label_formats          AS SELECT * FROM config.label_formats;
CREATE VIEW app.idempotency_keys       AS SELECT * FROM ops.idempotency_keys;
CREATE VIEW app.function_execution_log AS SELECT * FROM ops.function_execution_log;
CREATE VIEW app.capture_observations   AS SELECT * FROM ops.capture_observations;
CREATE VIEW app.mirror_replay_cursor   AS SELECT * FROM ops.mirror_replay_cursor;
CREATE VIEW app.mirror_replay_dlq      AS SELECT * FROM ops.mirror_replay_dlq;

COMMIT;

-- Widen the DB search_path: replace `app` with `auth, config, ops` (ahead of the
-- read/serving schemas so bare identity/i18n/plumbing names resolve to the new homes
-- once pools recycle). No cross-schema name collision among the 16 → unambiguous.
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, auth, config, ops, serving, customer_reports, core, public;
