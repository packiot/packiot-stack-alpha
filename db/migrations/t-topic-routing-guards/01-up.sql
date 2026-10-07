-- t-topic-routing-guards — schema P1 (2026-10-07): core.topic_routing gets its missing integrity + the tenant fence.
--
-- topic_routing (the PackML routing table, removed in ADR-0061 P5) still routes every SparkPlug metric until each
-- client switches, so until then it must be correct and fenced:
--   * active was NULLABLE, but uniqueness is `UNIQUE (packml_topic) WHERE active`: a NULL row is neither routed nor
--     deduped. -> NOT NULL (0 NULLs on staging 2026-10-07).
--   * id_unit (the routing target) and id_enterprise (the tenant) had no FK. -> FKs (0 orphans), NOT VALID then
--     VALIDATE so the scan does not block the stream-engine resolver.
--   * RLS GAP: readapi_ro (no BYPASSRLS) could SELECT every tenant's routing, directly and through
--     core.packml_register (a definer view owned by postgres, which bypasses table RLS). -> house tenant_isolation
--     policy + security_invoker on the view. Safe for current readers (checked 2026-10-07): readapi_ro only reads it
--     joined to core.equipments, which is already RLS-forced with the same tenant, and every routing row's tenant
--     equals its equipment's (0 mismatches); services read as postgres (superuser) and cloudbeaver_* have BYPASSRLS.
-- SET NOT NULL / ENABLE RLS / ALTER VIEW take brief ACCESS EXCLUSIVE locks (479 rows): lock_timeout 3 s + retry.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM core.topic_routing tr LEFT JOIN core.equipments e ON e.id_equipment = tr.id_equipment
   WHERE tr.active IS NULL OR tr.id_enterprise IS NULL OR tr.id_enterprise IS DISTINCT FROM e.id_enterprise;
  IF n > 0 THEN RAISE EXCEPTION 't-topic-routing-guards: % row(s) with NULL active/tenant or a tenant differing from the equipment; fix first', n; END IF;
END $$;

ALTER TABLE core.topic_routing ALTER COLUMN active SET NOT NULL;

ALTER TABLE core.topic_routing DROP CONSTRAINT IF EXISTS topic_routing_id_unit_fk;
ALTER TABLE core.topic_routing ADD CONSTRAINT topic_routing_id_unit_fk
  FOREIGN KEY (id_unit) REFERENCES core.equipments (id_equipment) NOT VALID;
ALTER TABLE core.topic_routing DROP CONSTRAINT IF EXISTS topic_routing_id_enterprise_fk;
ALTER TABLE core.topic_routing ADD CONSTRAINT topic_routing_id_enterprise_fk
  FOREIGN KEY (id_enterprise) REFERENCES core.enterprises (id_enterprise) NOT VALID;

ALTER TABLE core.topic_routing ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.topic_routing FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON core.topic_routing;
CREATE POLICY tenant_isolation ON core.topic_routing
  USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));
ALTER VIEW core.packml_register SET (security_invoker = true);
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE core.topic_routing VALIDATE CONSTRAINT topic_routing_id_unit_fk;
ALTER TABLE core.topic_routing VALIDATE CONSTRAINT topic_routing_id_enterprise_fk;
COMMIT;
