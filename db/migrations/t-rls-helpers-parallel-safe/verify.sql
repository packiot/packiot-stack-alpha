-- verify for t-rls-helpers-parallel-safe. label|value, expected value in the label. Read-only:
-- every role switch happens inside BEGIN READ ONLY … ROLLBACK. Run as postgres. ~1 s on staging.
--
-- V1–V2  the helpers' attributes.
-- V3     every policy calls the helpers only as scalar subqueries (InitPlans, evaluated once per
--        query, never per row) — the t-rls-initplan-policies shape still holds.
-- V4–V5  the planner may now build PARALLEL plans for a NOBYPASSRLS role: the policy runs as an
--        InitPlan and a Gather appears. Parallel costs are zeroed for the transaction so the plan
--        is deterministic on a tiny table (force_parallel_mode cannot be used: PG 15 never wraps a
--        top node that carries InitPlans — and every RLS query has them).
-- V6–V12 tenant isolation is unchanged, checked with those PARALLEL plans (workers scan with the
--        leader's InitPlan values and GUC state; a wrong hand-over would change the counts):
--        tenant-scoped readapi_ro sees only its tenant; a tenant that owns nothing sees nothing;
--        an unset GUC sees nothing (fail-closed); the -1 sentinel (stream_engine) sees everything.
\set ON_ERROR_STOP 1
\pset pager off
\pset footer off
\pset tuples_only on
\pset format unaligned

SELECT 'V1 current_tenant() volatile|parallel|leakproof: s|s|t',
       provolatile::text || '|' || proparallel::text || '|' || proleakproof::text
  FROM pg_proc WHERE oid = 'public.current_tenant()'::regprocedure;
SELECT 'V2 is_all_tenant()  volatile|parallel|leakproof: s|s|t',
       provolatile::text || '|' || proparallel::text || '|' || proleakproof::text
  FROM pg_proc WHERE oid = 'public.is_all_tenant()'::regprocedure;

SELECT 'V3 policies calling a tenant helper per row (not as (SELECT …)): 0',
       count(*) FILTER (WHERE
         regexp_count(coalesce(qual, '') || ' ' || coalesce(with_check, ''), '(current_tenant|is_all_tenant)\(\)')
         > regexp_count(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                        'SELECT (public\.)?(current_tenant|is_all_tenant)\(\)'))
  FROM pg_policies;

-- Fixtures (as postgres, RLS bypassed): a real tenant, its row counts, and the totals.
SELECT id_enterprise AS t FROM core.equipments GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1 \gset
SELECT count(*) AS t_eq FROM core.equipments WHERE id_enterprise = :t \gset
SELECT count(*) AS t_po FROM core.production_orders WHERE id_enterprise = :t \gset
SELECT count(*) AS t_rt FROM gold.production_orders_runtime r
  JOIN core.equipments e ON e.id_equipment = r.id_equipment WHERE e.id_enterprise = :t \gset
SELECT count(*) AS all_eq FROM core.equipments \gset
SELECT max(id_enterprise) + 100000 AS nobody FROM core.enterprises \gset

-- ── readapi_ro, scoped to tenant :t, parallel plans ───────────────────────────────────────────
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL ROLE readapi_ro;
SELECT set_config('app.tenant_id', :'t', true) IS NOT NULL AS _ \gset
SET LOCAL parallel_setup_cost = 0; SET LOCAL parallel_tuple_cost = 0; SET LOCAL min_parallel_index_scan_size = 0;   -- parallel plans even on
SET LOCAL min_parallel_table_scan_size = 0; SET LOCAL max_parallel_workers_per_gather = 1;  -- tiny tables
DO $$ DECLARE j json; BEGIN
  EXECUTE 'EXPLAIN (COSTS OFF, FORMAT JSON) SELECT count(*) FROM core.equipments' INTO j;
  PERFORM set_config('verify.plan', j::text, true);
END $$;
SELECT 'V4 readapi_ro plan over core.equipments has a Gather (parallel allowed): t',
       current_setting('verify.plan') ~ '"Node Type": "Gather"';
SELECT 'V5 ... and the tenant policy is an InitPlan, not a per-row call: t',
       current_setting('verify.plan') ~ '"Subplan Name": "InitPlan';
SELECT 'V6 readapi_ro (tenant ' || :t || ') sees its own equipments, all of them: t', count(*) = :t_eq,
       ' other tenants'' equipments: 0', count(*) FILTER (WHERE id_enterprise <> :t)
  FROM core.equipments;
SELECT 'V7 readapi_ro (tenant ' || :t || ') production orders = own, other tenants 0: true|0',
       (count(*) = :t_po)::text || '|' || count(*) FILTER (WHERE id_enterprise <> :t)
  FROM core.production_orders;
SELECT 'V8 readapi_ro (tenant ' || :t || ') PO runtime rows (policy via equipments) = own: t',
       count(*) = :t_rt FROM gold.production_orders_runtime;
ROLLBACK;

-- ── readapi_ro, a tenant that owns nothing / no tenant at all ─────────────────────────────────
BEGIN READ ONLY;
SET LOCAL ROLE readapi_ro;
SET LOCAL parallel_setup_cost = 0; SET LOCAL parallel_tuple_cost = 0; SET LOCAL min_parallel_index_scan_size = 0;   -- parallel plans even on
SET LOCAL min_parallel_table_scan_size = 0; SET LOCAL max_parallel_workers_per_gather = 1;  -- tiny tables
SELECT set_config('app.tenant_id', :'nobody', true) IS NOT NULL AS _ \gset
SELECT 'V9 readapi_ro as a tenant that owns nothing: equipments|POs|runtime 0|0|0',
       (SELECT count(*) FROM core.equipments) || '|' || (SELECT count(*) FROM core.production_orders)
       || '|' || (SELECT count(*) FROM gold.production_orders_runtime);
SELECT set_config('app.tenant_id', '', true) IS NOT NULL AS _ \gset
SELECT 'V10 readapi_ro with app.tenant_id unset (fail-closed): equipments 0', count(*) FROM core.equipments;
ROLLBACK;

-- ── stream_engine with its role default app.tenant_id = -1 (SET ROLE does not apply role
--    defaults, so it is set explicitly here, exactly as the login gets it) ─────────────────────
BEGIN READ ONLY;
SET LOCAL ROLE stream_engine;
SET LOCAL parallel_setup_cost = 0; SET LOCAL parallel_tuple_cost = 0; SET LOCAL min_parallel_index_scan_size = 0;   -- parallel plans even on
SET LOCAL min_parallel_table_scan_size = 0; SET LOCAL max_parallel_workers_per_gather = 1;  -- tiny tables
SELECT set_config('app.tenant_id', '-1', true) IS NOT NULL AS _ \gset
SELECT 'V11 stream_engine (-1 sentinel, parallel plan) sees every equipment: t', count(*) = :all_eq
  FROM core.equipments;
SELECT set_config('app.tenant_id', '', true) IS NOT NULL AS _ \gset
SELECT 'V12 stream_engine with the GUC cleared sees nothing (fail-closed): 0', count(*) FROM core.equipments;
ROLLBACK;
