-- t287-historian-cold-schema / 01-cold-schema.sql
-- ─────────────────────────────────────────────────────────────────────────────
-- Give the historian COLD-store + hot∪cold union + boundary objects their OWN
-- `cold` schema on the hist-gateway, SYMMETRIC with the hot `live` FDW schema.
-- Deferred R10 of the t282 gateway sweep ("same for the historian"), now approved.
--
-- WHY THIS IS SAFE / NON-DESTRUCTIVE:
--   * ALTER … SET SCHEMA is a pure catalog reparent — hypertable? no (these are
--     plain tables + pg_duckdb views); no data copy, no rewrite, PKs preserved.
--   * Inter-view dependencies are stored by OID, NOT by name: after ev_all's
--     source view `hist` and its boundary tables move to `cold`, ev_all keeps
--     resolving them (the pg_get_viewdef text merely re-renders qualified). So the
--     move needs NO view recreate and is order-independent.
--   * `live` (the hot FDW schema) is UNTOUCHED; ev_all/ev_all_events reference it
--     qualified (live.equipment_values) so that keeps resolving.
--   * pg_duckdb / postgres_fdw EXTENSION objects (read_parquet, duckdb.*, the
--     aggregates) STAY in public — they are not historian objects.
--
-- CONSUMER RESOLUTION: gateway-internal scripts (refresh-hist-cutover.sql,
-- refresh-ee-cutover.sql, stamp-hist-meta.sql, the staleness/coverage monitors)
-- reference these objects by UNQUALIFIED name and open fresh psql sessions, so we
-- add `cold` to the DB default search_path. This is a single-purpose gateway DB
-- whose only reason to exist is to serve the historian, so declaring its serving
-- schemas in the search_path is appropriate (public stays for the pg_duckdb funcs).
-- The EXTERNAL consumers (read-api /v1/historian, Superset ev_all dataset) are
-- repointed to the explicit `cold.ev_all` / `cold.ev_all_events` qualification —
-- symmetric with how they'd address `live.*`, and independent of the DB GUC.
--
-- Reversible: rollback-01-cold-schema.sql moves everything back and drops `cold`.
-- Idempotent-ish: re-running is a no-op for the DDL that already moved (the ALTERs
-- would error "already in schema"), so run ONCE; the rollback is the undo path.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;

CREATE SCHEMA IF NOT EXISTS cold;
COMMENT ON SCHEMA cold IS
  'Historian COLD-store + hot∪cold union serving schema (symmetric with `live`, the hot FDW schema). Holds the union VIEWS ev_all (EV) / ev_all_events (EE), the pg_duckdb read_parquet COLD source views hist / hist_ee, the per-enterprise disjointness boundary TABLES hist_cutover / ev_events_cutover, the R1 tenant-isolation allow-list hist_promoted_enterprise, and the R5 append-stamp hist_meta. Moved out of public (t287) so public holds ONLY the pg_duckdb/postgres_fdw extension objects. No RLS engine here — tenant fence is a caller-supplied id_enterprise literal.';

-- Boundary / config TABLES first (data + PK preserved; pure catalog reparent).
ALTER TABLE public.hist_cutover             SET SCHEMA cold;
ALTER TABLE public.ev_events_cutover        SET SCHEMA cold;
ALTER TABLE public.hist_promoted_enterprise SET SCHEMA cold;
ALTER TABLE public.hist_meta                SET SCHEMA cold;

-- VIEWS (OID-bound inter-view deps → any order works; cold sources then unions).
ALTER VIEW  public.hist                      SET SCHEMA cold;
ALTER VIEW  public.hist_ee                   SET SCHEMA cold;
ALTER VIEW  public.ev_all                    SET SCHEMA cold;
ALTER VIEW  public.ev_all_events             SET SCHEMA cold;

-- Serving-schema search_path for gateway-internal, unqualified-name scripts.
-- public MUST stay (pg_duckdb read_parquet lives there); live is always qualified.
ALTER DATABASE postgres SET search_path = cold, public;
SET search_path = cold, public;  -- also fix the remainder of THIS session

-- Re-home the two schema COMMENTs.
COMMENT ON SCHEMA public IS
  'pg_duckdb + postgres_fdw EXTENSION objects only (read_parquet, duckdb.*, the DuckDB aggregates). The historian serving objects moved to schema `cold` (t287). Do NOT create historian objects here.';

-- Read-only CloudBeaver browser role: extend its grants onto `cold` (its historian
-- SELECT surface moved there). Conditional — the role only exists when the gateway
-- was booted with CLOUDBEAVER_HISTRO_PASSWORD.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudbeaver_histro') THEN
    GRANT USAGE ON SCHEMA cold TO cloudbeaver_histro;
    GRANT SELECT ON ALL TABLES IN SCHEMA cold TO cloudbeaver_histro;
    ALTER DEFAULT PRIVILEGES IN SCHEMA cold GRANT SELECT ON TABLES TO cloudbeaver_histro;
  END IF;
END $$;

COMMIT;

-- Verification (read-only, prints post-move state).
\echo == post-move object homes ==
SELECT n.nspname AS schema, c.relname AS object, c.relkind
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relname IN ('hist','hist_ee','ev_all','ev_all_events',
                     'hist_cutover','ev_events_cutover','hist_promoted_enterprise','hist_meta')
 ORDER BY 1,2;
