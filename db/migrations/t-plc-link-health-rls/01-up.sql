-- t-plc-link-health-rls — tenant isolation on silver.plc_link_minutes (2026-10-01)
-- The data-architecture audit (t-data-invariants, check family T) found tables with an
-- id_enterprise column readable by readapi_ro without RLS; this one was created the same
-- day (t-plc-link-health), so it gets the standard policy now. Writers/readers in the
-- pipeline (sparkplug-agent linkhealth, stream-engine deriver) connect as postgres
-- (superuser, BYPASSRLS) and are unaffected; readapi_ro sees only its tenant.
BEGIN;
ALTER TABLE silver.plc_link_minutes ENABLE ROW LEVEL SECURITY;
ALTER TABLE silver.plc_link_minutes FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON silver.plc_link_minutes;
CREATE POLICY tenant_isolation ON silver.plc_link_minutes
    USING ((SELECT is_all_tenant()) OR id_enterprise = (SELECT current_tenant()));
COMMIT;
