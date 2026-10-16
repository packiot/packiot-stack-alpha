-- t280 — serving.* VIEWS: security_invoker = on  (closes the #264 view-path hole)
--
-- WHY (task GAP-5 / appschemas-column-redesign.md P1)
-- ──────────────────────────────────────────────────
-- #264/t276 put read-api under the NOBYPASSRLS role `readapi_ro` and made read-api
-- stamp `app.tenant_id` per query, so Postgres RLS (FORCE ROW LEVEL SECURITY on
-- core.equipments / core.production_orders / core.production_targets /
-- gold.equipment_oee_hourly / _shift / production_orders_runtime, policy
-- `is_all_tenant() OR id_enterprise = current_tenant()`) CO-ENFORCES the same
-- server-derived tenant the app-layer `WHERE id_enterprise=$1` fence already applies.
--
-- BUT all 9 serving.* VIEWS are owned by `postgres` (rolbypassrls=t) and are DEFAULT
-- (definer-semantics) views. A definer view evaluates the base-table RLS in the VIEW
-- OWNER's context — postgres — so RLS is BYPASSED on the view path regardless of who
-- queries. Proven on staging: `SET ROLE readapi_ro; set_config('app.tenant_id','3',true);
-- SELECT count(*) FROM serving.v_events_2` returned 146361 rows (ALL tenants), NOT
-- tenant-3-scoped. The app-layer $1 fence is the only thing scoping read-api today; the
-- moment any dataset ships without that fence, the definer view leaks every tenant.
--
-- FIX. `security_invoker = on` (PG15+ idiom) makes each view evaluate base-table RLS in
-- the QUERYING role's context. read-api (readapi_ro, NOBYPASSRLS, app.tenant_id stamped)
-- then gets RLS-scoped rows; the other consumers connect as `postgres` (BYPASSRLS —
-- edge-api session-dao, oeecloud, operator-gateway) so they are UNAFFECTED (bypass holds
-- either way). No ownership churn; no base-table grant churn (readapi_ro already holds
-- SELECT on all base tables from t276).
--
-- The 45 serving.* FUNCTIONS are already SECURITY INVOKER (prosecdef=f) — not the gap.
--
-- Additive/behavioral only (no DDL on the view body). Reversible: rollback.sql flips each
-- back to security_invoker=off.

ALTER VIEW serving.production_information            SET (security_invoker = on);
ALTER VIEW serving.v_entities_per_user_role          SET (security_invoker = on);
ALTER VIEW serving.v_entities_per_user_role_operator SET (security_invoker = on);
ALTER VIEW serving.v_events_2                        SET (security_invoker = on);
ALTER VIEW serving.v_menu_per_user_role              SET (security_invoker = on);
ALTER VIEW serving.v_operator_entities_2             SET (security_invoker = on);
ALTER VIEW serving.v_operator_po_details_3           SET (security_invoker = on);
ALTER VIEW serving.v_operator_po_list_setup_4        SET (security_invoker = on);
ALTER VIEW serving.v_report_downtimes                SET (security_invoker = on);
