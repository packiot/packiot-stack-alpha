-- t-rls-helpers-parallel-safe — mark the RLS tenant helpers PARALLEL SAFE + LEAKPROOF (2026-10-14).
--
-- SYMPTOM. After stream-engine moved from postgres (SUPERUSER, BYPASSRLS) to stream_engine
-- (NOBYPASSRLS, role default app.tenant_id='-1', t-stream-engine-role) its SELECTs over FORCE-RLS
-- tables lost every parallel plan. A/B on staging, same statement, same minute, warm cache:
--   events closer selection     postgres 14.0 s (Gather, 1 worker)       stream_engine 16.9 s (no Gather)
--   CPACK shadow-deriver insert postgres 2.3–2.5 s (Gather Merge)        stream_engine 2.9–3.1 s (none)
-- readapi_ro / histgw_ro / bi_owner pay the same tax on every dashboard query that touches an RLS table.
--
-- ROOT CAUSE. public.current_tenant() and public.is_all_tenant() were created PARALLEL UNSAFE (the
-- CREATE FUNCTION default). Every tenant_isolation policy calls them, the rewriter adds the policy
-- quals before planning, and standard_planner() checks parallel safety on that whole query tree
-- before any SQL-function inlining: one parallel-unsafe call anywhere → no parallel plan for the
-- whole statement. Superusers never saw it because BYPASSRLS skips the policies.
-- (The policies themselves are already the InitPlan shape — (SELECT public.is_all_tenant()) OR
-- id_enterprise = (SELECT public.current_tenant()) — since t-rls-initplan-policies; verify.sql V3.)
--
-- WHY THIS IS CORRECT
--   * PARALLEL SAFE: the bodies only read the GUC app.tenant_id through current_setting(), which is
--     itself PARALLEL SAFE. A parallel leader serialises its GUC state (SET, SET LOCAL and the role
--     default alike) to every worker, and SET is refused while in parallel mode, so a worker always
--     sees the leader's tenant. verify.sql V6–V8 prove isolation under a FORCED parallel plan.
--   * LEAKPROOF: both take no arguments, so they cannot reveal anything about a row. Marking them
--     lets the planner use quals like `id_enterprise = current_tenant()` below the security
--     barrier (index quals on RLS tables). Setting LEAKPROOF needs a superuser: apply as postgres.
--   * STABLE is unchanged (re-stated so the intent is in one place). No body, owner, grant or
--     policy changes: who sees what is exactly the same for every role.
--
-- Idempotent (ALTER re-asserts attributes). No table locks: ALTER FUNCTION only updates pg_proc and
-- invalidates cached plans that use the functions. Rollback: rollback.sql.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

ALTER FUNCTION public.current_tenant() STABLE PARALLEL SAFE LEAKPROOF;
ALTER FUNCTION public.is_all_tenant()  STABLE PARALLEL SAFE LEAKPROOF;

COMMENT ON FUNCTION public.current_tenant() IS
  'RLS tenant helper: the session GUC app.tenant_id as int, NULL when unset/blank (policies then deny). '
  'STABLE PARALLEL SAFE LEAKPROOF (t-rls-helpers-parallel-safe): parallel-unsafe helpers disabled parallel '
  'plans for every query a NOBYPASSRLS role ran over an RLS table. Defined in db/superset/02-tenant-rls.sql.';
COMMENT ON FUNCTION public.is_all_tenant() IS
  'RLS tenant helper: true when app.tenant_id = -1 (the all-tenant sentinel: stream_engine, histgw_ro, '
  'the Superset admin session). STABLE PARALLEL SAFE LEAKPROOF (t-rls-helpers-parallel-safe). '
  'Defined in db/superset/02-tenant-rls.sql.';

COMMIT;
