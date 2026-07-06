-- ADR-0012 Wave 4 — CONTRACT: retire version-sprawl + dead objects.
-- PREPARED 2026-07-06; EXECUTES ONLY AFTER:
--   1. the flip (0016-flip-runbook.md) is live, AND
--   2. the 30-day soak has elapsed, AND
--   3. the preflight below shows ZERO reads on every target, AND
--   4. c35 drop sign-off (issue #224) for §C.
--
-- Run §A (baseline capture) AT THE FLIP. Run §B (preflight) + §C/§D
-- (drops) at soak expiry. One precise predicate per destructive
-- cleanup — golden rule.

-- ============================================================
-- §A — soak baseline capture (run AT the flip, then never again)
-- ============================================================
CREATE TABLE IF NOT EXISTS ops.wave4_soak_baseline AS
SELECT now() AS captured_at, relname,
       COALESCE(seq_scan, 0) AS seq_scan, COALESCE(idx_scan, 0) AS idx_scan
FROM pg_stat_user_tables
WHERE relname IN (
  'shift_agg_from_events_v3', 'shift_agg_from_events_v4',
  'monitoramento_execucao_functions',
  'c35_dashboard_paradas_24h', 'c35_dashboard_producao_24h',
  'c35_dashboard_timeline_24h');
-- (views v_operator_po_details_2/_3, v_events_2 have no pg_stat rows;
--  their soak evidence = pg_stat on their base tables is unchanged AND
--  repo grep shows zero references — verified 2026-07-02 inventory.)

-- ============================================================
-- §B — preflight (MUST return zero rows; any row = ABORT Wave 4)
-- ============================================================
SELECT b.relname,
       s.seq_scan - b.seq_scan AS seq_reads_during_soak,
       COALESCE(s.idx_scan, 0) - b.idx_scan AS idx_reads_during_soak
FROM ops.wave4_soak_baseline b
JOIN pg_stat_user_tables s USING (relname)
WHERE (s.seq_scan - b.seq_scan) + (COALESCE(s.idx_scan,0) - b.idx_scan) > 0
  AND now() >= b.captured_at + INTERVAL '30 days';

-- ============================================================
-- §C — c35 dead dashboards (GATED on issue #224 sign-off)
-- ============================================================
-- Prod evidence (2026-07-02): zero writes since stats reset, one
-- lifetime seq_scan, no writer in pg_proc or any repo. EBS snapshot
-- before drop (flip-runbook rollback discipline).
BEGIN;
DROP TABLE IF EXISTS public.c35_dashboard_paradas_24h;
DROP TABLE IF EXISTS public.c35_dashboard_producao_24h;
DROP TABLE IF EXISTS public.c35_dashboard_timeline_24h;
COMMIT;

-- ============================================================
-- §D — version-sprawl + pt-BR insert-only log
-- ============================================================
BEGIN;
-- shift_agg_from_events: base + _v2 KEEP (1 prod dependent each);
-- _v3/_v4 verified 0 dependents (2026-07-01 audit).
DROP VIEW IF EXISTS public.shift_agg_from_events_v3;
DROP VIEW IF EXISTS public.shift_agg_from_events_v4;
DROP VIEW IF EXISTS public.v_operator_po_details_2;
DROP VIEW IF EXISTS public.v_operator_po_details_3;
DROP VIEW IF EXISTS public.v_events_2;
-- 67MB staging / 2.1GB prod, insert-only, 0 idx_scans ever. App-repo
-- grep (edge-api, primary-api, back4-api, reports) must be re-run at
-- execution time — last verified 2026-07-02.
DROP TABLE IF EXISTS public.monitoramento_execucao_functions;
COMMIT;

-- ============================================================
-- Post-contract verification
-- ============================================================
SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND relname IN (
  'shift_agg_from_events_v3','shift_agg_from_events_v4',
  'v_operator_po_details_2','v_operator_po_details_3','v_events_2',
  'monitoramento_execucao_functions','c35_dashboard_paradas_24h',
  'c35_dashboard_producao_24h','c35_dashboard_timeline_24h');
-- expected: zero rows
