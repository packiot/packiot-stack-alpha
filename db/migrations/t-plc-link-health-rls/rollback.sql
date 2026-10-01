BEGIN;
DROP POLICY IF EXISTS tenant_isolation ON silver.plc_link_minutes;
ALTER TABLE silver.plc_link_minutes NO FORCE ROW LEVEL SECURITY;
ALTER TABLE silver.plc_link_minutes DISABLE ROW LEVEL SECURITY;
COMMIT;
