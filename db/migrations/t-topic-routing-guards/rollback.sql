-- rollback for t-topic-routing-guards.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER VIEW core.packml_register RESET (security_invoker);
DROP POLICY IF EXISTS tenant_isolation ON core.topic_routing;
ALTER TABLE core.topic_routing NO FORCE ROW LEVEL SECURITY;
ALTER TABLE core.topic_routing DISABLE ROW LEVEL SECURITY;
ALTER TABLE core.topic_routing DROP CONSTRAINT IF EXISTS topic_routing_id_unit_fk;
ALTER TABLE core.topic_routing DROP CONSTRAINT IF EXISTS topic_routing_id_enterprise_fk;
ALTER TABLE core.topic_routing ALTER COLUMN active DROP NOT NULL;
COMMIT;
