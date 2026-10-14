-- t-readapi-screen-config — own identity.user_screen_config in a migration, not in read-api's boot path.
--
-- WHY
-- read-api used to run this DDL at every boot (ensureSchema in services/read-api/cmd/refdata-api/query.go):
-- CREATE SCHEMA identity, CREATE TABLE identity.user_screen_config, ALTER TABLE … ADD COLUMN / DROP CONSTRAINT,
-- CREATE UNIQUE INDEX. Since t276 read-api runs as readapi_ro (no CREATE, owns nothing), so every boot logged
-- "permission denied" in Postgres and the Go side swallowed it. A read API must not issue DDL; the boot code now
-- only checks the table exists and that the login can read and upsert it.
--
-- STAGING / PROD STATE
-- staging packiot_analytics already has this table (moved gold → auth → identity by t237/t241/t247, keyed by
-- user_screen_config_tenant_key since ADR-0027 Surface-1), and t276 already granted readapi_ro SELECT, INSERT,
-- UPDATE. On staging this file is therefore a NO-OP (every statement is IF NOT EXISTS / guarded; no lock is taken
-- unless something is actually missing). It exists so a fresh database (dev seed rebuild, the production
-- transplant target) gets the table from a migration instead of from a service.
--
-- Run as the table owner (postgres). Idempotent: up → up is a no-op.
\set ON_ERROR_STOP 1
BEGIN;

CREATE SCHEMA IF NOT EXISTS identity;

CREATE TABLE IF NOT EXISTS identity.user_screen_config (
  id_enterprise int         NOT NULL DEFAULT 0,
  id_user       text        NOT NULL,
  screen        text        NOT NULL,
  config        jsonb       NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now());

-- Pre-Surface-1 forward migration (old PK was (id_user, screen); rows backfilled to id_enterprise = 0, an
-- unreachable tenant). Guarded so a current table takes no ACCESS EXCLUSIVE lock.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'identity' AND table_name = 'user_screen_config'
                    AND column_name = 'id_enterprise') THEN
    ALTER TABLE identity.user_screen_config ADD COLUMN id_enterprise int NOT NULL DEFAULT 0;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'identity.user_screen_config'::regclass
                AND conname = 'user_screen_config_pkey') THEN
    ALTER TABLE identity.user_screen_config DROP CONSTRAINT user_screen_config_pkey;
  END IF;
END $$;

-- The ON CONFLICT target of PUT /v1/screen-config.
CREATE UNIQUE INDEX IF NOT EXISTS user_screen_config_tenant_key
  ON identity.user_screen_config (id_enterprise, id_user, screen);

COMMENT ON TABLE identity.user_screen_config IS
  'Per-user UI layout JSON keyed (id_enterprise, id_user, screen). Written only by read-api PUT /v1/screen-config '
  '(readapi_ro: SELECT, INSERT, UPDATE; no DELETE). Owned by migration t-readapi-screen-config, never created at boot.';

-- readapi_ro's grant on this table, same set as t276 (re-asserted so a fresh DB where the table is created
-- after t276 ends up identical). It is the role's only INSERT/UPDATE besides identity.users UPDATE (t276).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'readapi_ro') THEN
    GRANT USAGE ON SCHEMA identity TO readapi_ro;
    GRANT SELECT, INSERT, UPDATE ON identity.user_screen_config TO readapi_ro;
  END IF;
END $$;

COMMIT;
