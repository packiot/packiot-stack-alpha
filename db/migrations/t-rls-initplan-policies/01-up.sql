-- t-rls-initplan-policies — tenant RLS policies evaluated ONCE per query, not per row.
--
-- SYMPTOM (2026-09-24): front4 Downtimes (CPACK, "This Month") never loaded — read-api
-- `downtimes-per-category` returned 500 after its 40 s timeout. serving.downtime_by_category
-- takes 1.9 s as the superuser but 61 s as readapi_ro (week: 18.5 s): RLS, not the SQL.
-- ROOT CAUSE: the reached-via-equipments policies (equipment_oee_shift/_hourly,
-- production_orders_runtime) were `is_all_tenant() OR EXISTS (SELECT 1 FROM equipments e
-- WHERE e.id_equipment = <row>.id_equipment AND e.id_enterprise = current_tenant())` — a
-- correlated subquery per row (itself under equipments' RLS), and the non-LEAKPROOF helpers
-- stop the planner pushing the query's own filters below the security barrier.
-- FIX (standard RLS shape): wrap helpers in scalar subqueries → InitPlans evaluated once;
-- reached-via policies become `id_equipment = ANY (ARRAY(<tenant's equipment ids>))`.
-- Same semantics (membership in the tenant's id set ⇔ the EXISTS; unset GUC → empty set →
-- fail-closed; -1 → all). Proven by the 2-tenant isolation gate (10/10) + live per-tenant
-- row-count parity (3, 5, -1, unset) before/after.
-- APPLY: each policy swapped in its own tiny tx (DROP+CREATE atomic → never policy-less),
-- lock_timeout 3s (DROP POLICY takes AccessExclusiveLock on a hot table) — run via
-- scripts/ops/apply-in-short-txns.sh or statement-by-statement with retry.

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON core.equipments;
CREATE POLICY tenant_isolation ON core.equipments USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON core.production_orders;
CREATE POLICY tenant_isolation ON core.production_orders USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON config.production_targets;
CREATE POLICY tenant_isolation ON config.production_targets USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON serving.downtime_events_resolved;
CREATE POLICY tenant_isolation ON serving.downtime_events_resolved USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON gold.equipment_oee_shift;
CREATE POLICY tenant_isolation ON gold.equipment_oee_shift USING ((SELECT public.is_all_tenant()) OR id_equipment = ANY (ARRAY(SELECT e.id_equipment FROM core.equipments e WHERE e.id_enterprise = (SELECT public.current_tenant()))));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON gold.equipment_oee_hourly;
CREATE POLICY tenant_isolation ON gold.equipment_oee_hourly USING ((SELECT public.is_all_tenant()) OR id_equipment = ANY (ARRAY(SELECT e.id_equipment FROM core.equipments e WHERE e.id_enterprise = (SELECT public.current_tenant()))));
COMMIT;

BEGIN; SET LOCAL lock_timeout = '3s';
DROP POLICY IF EXISTS tenant_isolation ON gold.production_orders_runtime;
CREATE POLICY tenant_isolation ON gold.production_orders_runtime USING ((SELECT public.is_all_tenant()) OR id_equipment = ANY (ARRAY(SELECT e.id_equipment FROM core.equipments e WHERE e.id_enterprise = (SELECT public.current_tenant()))));
COMMIT;
