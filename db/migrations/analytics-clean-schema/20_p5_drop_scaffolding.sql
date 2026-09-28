-- P5 (partial) — drop the consumer-free scaffolding: equivalence-gate twins + PoC + backup.
-- ============================================================================
-- All three verified 0 external consumers on staging (2026-09-08):
--   bi_next.*            — the security_invoker equivalence-gate scaffolding (Decision #3
--                          keeps bi.* as security-DEFINER; bi_next was only ever the gate twin).
--                          0 views/fns outside bi_next reference it.
--   analytics_v2.*       — the original PoC (6 views) promoted into silver.*; 0 external fn refs.
-- Both are recreatable from committed SQL (bi_next ← 06_p2_bi_next_security_invoker_views.sql;
-- analytics_v2 ← db/design/analytics-v2.sql) so the CASCADE drop is reversible.
--
-- DEFERRED (NOT dropped here): drop_backup_20260908 (8 backup tables) — the rollback net for the
-- P0c drops. KEEP until the FULL cutover (P3 read-api deploy + P4 + P5 h_piot cull) is signed off.
-- ============================================================================
DROP SCHEMA IF EXISTS bi_next CASCADE;
DROP SCHEMA IF EXISTS analytics_v2 CASCADE;
