-- verify for t-topic-routing-guards. label|value, expected in the label. Read-only apart from SET ROLE/GUC (reset).
\set ON_ERROR_STOP 1
SELECT 'V1 active NOT NULL: t', attnotnull FROM pg_attribute WHERE attrelid = 'core.topic_routing'::regclass AND attname = 'active';
SELECT 'V2 both FKs validated: 2', count(*) FROM pg_constraint
 WHERE conrelid = 'core.topic_routing'::regclass AND conname IN ('topic_routing_id_unit_fk', 'topic_routing_id_enterprise_fk') AND convalidated;
SELECT 'V3 RLS enabled+forced, policy, view security_invoker: t|t|1|t', c.relrowsecurity, c.relforcerowsecurity,
       (SELECT count(*) FROM pg_policies WHERE schemaname = 'core' AND tablename = 'topic_routing'),
       (SELECT coalesce('security_invoker=true' = ANY (v.reloptions), false) FROM pg_class v WHERE v.oid = 'core.packml_register'::regclass)
  FROM pg_class c WHERE c.oid = 'core.topic_routing'::regclass;
SELECT count(*) AS want3 FROM core.topic_routing WHERE id_enterprise = 3 \gset
SET ROLE readapi_ro;
SET app.tenant_id = '3';
SELECT 'V4 readapi_ro as tenant 3 sees only tenant 3 via the view: 0', count(*) FROM core.packml_register WHERE id_enterprise <> 3;
SELECT 'V5 readapi_ro as tenant 3 sees ALL of tenant 3 (= superuser count): t', count(*) = :want3 FROM core.packml_register;
SELECT 'V6 the downtime-style join still returns tenant 3 rows: > 0', count(*) FROM core.equipments e JOIN core.packml_register p ON p.id_equipment = e.id_equipment;
RESET app.tenant_id;
SELECT 'V7 readapi_ro unscoped sees: 0', count(*) FROM core.packml_register;
RESET ROLE;
SELECT 'V8 superuser (services) still sees every row: t', count(*) = (SELECT count(*) FROM core.topic_routing) FROM core.packml_register;
