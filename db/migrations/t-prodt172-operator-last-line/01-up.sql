-- t-prodt172-operator-last-line — PRODT-172 RN-03: the line an Operator user lands on at login.
--
-- WHY
-- RN-03 (docs/specs/PRODT-157-operator-app.md): on login the Operator opens the LAST line the user viewed, stored
-- per user AND per enterprise on the SERVER (so it follows the user to any tablet), if still permitted. edge-api
-- (PR "line grants, last line and supervisor-approved time-corrections") writes it on every line switch
-- (POST /api/operator/last-line) and returns it from /session (last_line_id). One row per (user, enterprise): a
-- super-admin who works in several tenants has one landing line per tenant.
--
-- No FKs on purpose: identity.users rows are reflected/healed by other jobs (prod mirror, sandbox heal) and a
-- landing-line row must never block those; edge-api only ever reads a row back for the verified user and checks
-- the line against the user's grant before using it (a stale id simply reads as "no last line").
--
-- edge-api ALSO ships an idempotent knex mirror (migrations/20261016000001_create_operator_last_line.ts) for its CI
-- DB / fresh dev DBs; it is a no-op when this table already resolves through search_path. Apply THIS file first on
-- staging/production so the table lands in `identity` with the grant below.
--
-- Run as postgres. Idempotent: up → up is a no-op. Rollback: rollback.sql.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE SCHEMA IF NOT EXISTS identity;

CREATE TABLE IF NOT EXISTS identity.operator_last_line (
  id_user       integer     NOT NULL,
  id_enterprise integer     NOT NULL,
  id_equipment  integer     NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT operator_last_line_pkey PRIMARY KEY (id_user, id_enterprise));

COMMENT ON TABLE identity.operator_last_line IS
  'PRODT-172 RN-03: last line an Operator user viewed, per (user, enterprise). Written by edge-api '
  'POST /api/operator/last-line, read by /session. Owned by migration t-prodt172-operator-last-line.';

-- edge-api connects as the application login that owns identity.users (it created the app tables through its knex
-- migrations). Give that role DML on the new table; a no-op when it is postgres itself. No other role needs it
-- (read-api, the reflector and the engine never read the landing line).
DO $$
DECLARE app_owner text := (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass('identity.users'));
BEGIN
  IF app_owner IS NOT NULL AND app_owner <> current_user THEN
    EXECUTE format('GRANT USAGE ON SCHEMA identity TO %I', app_owner);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON identity.operator_last_line TO %I', app_owner);
  END IF;
END $$;

COMMIT;
