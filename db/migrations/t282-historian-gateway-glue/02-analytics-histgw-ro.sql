-- t282 · R9 — read-only REMOTE FDW identity for the historian-gateway browser role.
--
-- TARGET DB: packiot_analytics on 10.10.10.89 (the LIVE analytics timescaledb) —
--   NOT the hist-gateway. Run as postgres/superuser there.
--
-- WHY (historian-gateway-schema-sweep.md R9, defense-in-depth)
-- ───────────────────────────────────────────────────────────
-- The hist-gateway's cloudbeaver_histro browser role (NOSUPERUSER, SELECT-only)
-- reaches the HOT side of ev_all / ev_all_events through postgres_fdw. Its user
-- mapping on server live_pg mapped to the REMOTE `postgres` SUPERUSER — so a
-- compromised gateway browser session could ride a superuser identity into the
-- analytics DB. This mints a least-privilege remote role that can read ONLY the two
-- silver fact tables the gateway foreign-mounts, and 01-gateway.sql repoints the
-- cloudbeaver_histro user mapping to it.
--
-- SAFE UNDER RLS: silver.equipment_values / silver.equipment_events carry NO row
-- security (relrowsecurity=f, relforcerowsecurity=f — verified live 2026-09-14), so a
-- NOBYPASSRLS role reads every row through the FDW (unlike the core/gold FORCE-RLS
-- tables, which would deny-all a GUC-less FDW session). This role is deliberately
-- scoped to the two facts only — it is NOT a general read replica of the analytics DB.
--
-- Reversible: rollback-02-analytics-histgw-ro.sql (revoke + drop role).
-- Secret: pass the password as a psql var so it never lands in git —
--   psql -v histgw_ro_pass='<secret>' -f 02-analytics-histgw-ro.sql
-- The SAME secret must be given to 01-gateway.sql's user-mapping repoint and stored
-- in the gateway .env as HISTGW_RO_PASS (see the gateway compose/init).

\set ON_ERROR_STOP on

-- Create-or-alter without a DO block: psql does NOT substitute :'var' inside a
-- dollar-quoted ($$…$$) body, so the password must stay at top level.
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'histgw_ro') AS histgw_ro_absent \gset
\if :histgw_ro_absent
CREATE ROLE histgw_ro LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'histgw_ro_pass';
\else
ALTER ROLE histgw_ro PASSWORD :'histgw_ro_pass';
\endif

COMMENT ON ROLE histgw_ro IS
  'Least-privilege REMOTE identity for the historian-gateway FDW (server live_pg, '
  'user mapping for cloudbeaver_histro). SELECT on silver.equipment_values + '
  'silver.equipment_events ONLY. NOSUPERUSER/NOBYPASSRLS — replaces the former '
  'superuser FDW identity for the gateway browser role (sweep R9). Not a general '
  'read replica: extend grants only if the gateway foreign-mounts another table.';

GRANT USAGE ON SCHEMA silver TO histgw_ro;
GRANT SELECT ON silver.equipment_values TO histgw_ro;
GRANT SELECT ON silver.equipment_events TO histgw_ro;
