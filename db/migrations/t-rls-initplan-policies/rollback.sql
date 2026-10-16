-- rollback t-rls-initplan-policies: restore the original per-row policies.

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON core.equipments;
CREATE POLICY tenant_isolation ON core.equipments USING (public.is_all_tenant() OR id_enterprise = public.current_tenant());
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON core.production_orders;
CREATE POLICY tenant_isolation ON core.production_orders USING (public.is_all_tenant() OR id_enterprise = public.current_tenant());
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON config.production_targets;
CREATE POLICY tenant_isolation ON config.production_targets USING (public.is_all_tenant() OR id_enterprise = public.current_tenant());
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON serving.downtime_events_resolved;
CREATE POLICY tenant_isolation ON serving.downtime_events_resolved USING (public.is_all_tenant() OR id_enterprise = public.current_tenant());
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON gold.equipment_oee_shift;
CREATE POLICY tenant_isolation ON gold.equipment_oee_shift USING (public.is_all_tenant() OR EXISTS (SELECT 1 FROM core.equipments e WHERE e.id_equipment = equipment_oee_shift.id_equipment AND e.id_enterprise = public.current_tenant()));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON gold.equipment_oee_hourly;
CREATE POLICY tenant_isolation ON gold.equipment_oee_hourly USING (public.is_all_tenant() OR EXISTS (SELECT 1 FROM core.equipments e WHERE e.id_equipment = equipment_oee_hourly.id_equipment AND e.id_enterprise = public.current_tenant()));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON gold.production_orders_runtime;
CREATE POLICY tenant_isolation ON gold.production_orders_runtime USING (public.is_all_tenant() OR EXISTS (SELECT 1 FROM core.equipments e WHERE e.id_equipment = production_orders_runtime.id_equipment AND e.id_enterprise = public.current_tenant()));
COMMIT;
