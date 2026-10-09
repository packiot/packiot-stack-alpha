-- Rollback t276 — remove readapi_ro.
--
-- Reversal sequence: revoke everything the role was granted (incl. default privileges),
-- then drop the role. DROP ROLE fails if the role still owns objects or holds grants, so
-- REVOKE first. read-api must already be repointed back to ${POSTGRES_USER} (revert the
-- compose.staging.yml change) before running this, or its next connection will fail.

-- Undo default privileges (must mirror the grants exactly, incl. the granting role).
ALTER DEFAULT PRIVILEGES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  REVOKE SELECT ON TABLES FROM readapi_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA
  serving, core, silver, gold, config, identity, bi, customer_reports, public
  REVOKE EXECUTE ON FUNCTIONS FROM readapi_ro;

-- Undo explicit grants (belt-and-suspenders; DROP OWNED covers the rest).
REVOKE ALL ON identity.user_screen_config FROM readapi_ro;
REVOKE ALL ON identity.users FROM readapi_ro;

-- DROP OWNED cleans up every remaining privilege the role holds in this DB.
DROP OWNED BY readapi_ro;

DROP ROLE IF EXISTS readapi_ro;
