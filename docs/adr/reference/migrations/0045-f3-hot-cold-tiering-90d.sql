-- 0045-f3-hot-cold-tiering-90d.sql
-- ═══════════════════════════════════════════════════════════════════════════
-- F3 HOT / COLD DATA TIERING — make the S3 historian a real TIER, not a copy.
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT CHANGES (and why it REVERSES 0036-b0)
-- ──────────────────────────────────────────
-- 0036-b0 (2026-07-23) grew raw `equipment_values` retention 180d → **2 years**
-- and enabled 14-day compression, on the explicit premise that F3 Bronze was the
-- *only* multi-year, immutable REPLAY source of truth — so it could not be allowed
-- to truncate. That premise is now OBSOLETE: the S3 + Parquet + Athena historian
-- (terraform/production/historian.tf) holds the FULL raw archive FOREVER
-- (CPACK backfill 2021 → 2026-08 complete; daily incremental append keeps it
-- current). The historian is now the cold, forever tier. F3 therefore only needs
-- to keep raw HOT for the operational window. USER-APPROVED hot window = **90 days**.
--
-- This migration, on `equipment_values` ONLY:
--   1. Compression policy: compress chunks older than **7 days** (was 14d) — the
--      hot upsert window stays uncompressed; 7-90d cold data is columnstore
--      (~33x measured), shrinking the hot-window footprint too.
--   2. Retention policy: drop raw chunks older than **90 days** (was 2y / 180d).
--      This is the tiering guillotine — but it is SAFE because every dropped row
--      is already in the historian (see SAFETY below).
--
-- SCOPE — `equipment_values` ONLY. Deliberately NOT changed here:
--   • equipment_events            — small, NOT archived by the historian; keep the
--                                   0036-b0 2-year retention (do not 90d-drop it).
--   • equipment_values_raw / _raw — the ADR-0045 pre-decode capture layer; NOT
--                                   archived by the historian; leave its policy.
--   • lab_equipment_values        — 1-year retention (0036-b0 R1b); unchanged.
--   • agg_*/ca_* continuous aggregates & equipment_runtime_* — the downsampled OEE
--                                   tiers; kept long-term, NEVER retention-dropped.
-- The historian append (scripts/historian-append.sh) projects exactly
-- `equipment_values` → S3, so `equipment_values` is the one table for which the
-- cold tier exists and the 90d drop is loss-free.
--
-- ⚠️ SAFETY — NON-NEGOTIABLE (F3 must never drop raw the historian lacks)
-- ────────────────────────────────────────────────────────────────────────────
-- Retention @ 90d is only safe once BOTH hold:
--   (A) Historian backfill complete for the tenant  — DONE for CPACK (2021→2026-08).
--   (B) Daily append LIVE and CAUGHT UP             — historian covers up to
--       ~yesterday, i.e. far past the 90-day drop horizon.
-- Because 90d >> the ~1-day append lag, (B) gives ~89 days of margin: nothing the
-- append could miss is anywhere near the drop horizon. SEQUENCING IS MANDATORY:
--   append-live-and-caught-up  →  THEN enable this retention.
-- On a freshly-onboarded tenant whose oldest F3 chunk is < 90 days old, this
-- policy DROPS ZERO ROWS on install (verified: staging/prod CPACK data starts
-- 2026-07, oldest chunk << 90d as of 2026-08) — so installing it early is inert,
-- and its FIRST real drop (~2026-10 for CPACK) lands well after the append has
-- been proven. Do NOT install this on a tenant lacking a complete historian
-- backfill + a running append.
--
-- ⚠️ CONTINUOUS-AGGREGATE MATERIALIZATION must precede the raw drop.
-- Dropping raw > 90d must not lose aggregated OEE. It does not: every cagg over
-- `equipment_values` refreshes with a SMALL, FINITE start_offset (verified live:
-- agg_* = 2h/3d, ca_agg_equipment_values_1min/_1hour = 2 days) — i.e. buckets are
-- materialized within ~2-3 days of real time, ~87 days BEFORE the raw beneath them
-- is dropped. Once materialized, cagg results live in their own materialization
-- hypertables and are NOT cascade-deleted when source chunks are dropped. So the
-- OEE history (minute/hour/shift/day rollups) survives the raw guillotine intact.
--
-- SCOPE / SAFETY (operational)
--   • STAGING first (packiot_shadow), then PROD-GATED (packiot) under the normal
--     prod-apply gate, AFTER the append is confirmed running + caught up on prod.
--   • Additive + reversible + idempotent (remove-then-add converges the horizon).
--   • Apply via scripts/ssm-psql.sh, like migrations 29-35 / 0036-b0.
--   • Legacy (packiot40 PG12) is SELECT-ONLY — NEVER run this there.
--
-- ROLLBACK (documented at bottom) restores the 0036-b0 2y retention + 14d compress.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

DO $tier$
DECLARE
  hot_window     CONSTANT interval := INTERVAL '90 days';  -- USER-APPROVED hot raw window
  compress_after CONSTANT interval := INTERVAL '7 days';   -- warm→columnstore boundary
  n_over_horizon bigint;
BEGIN
  IF to_regclass('public.equipment_values') IS NULL THEN
    RAISE NOTICE 'equipment_values absent — nothing to do'; RETURN;
  END IF;

  -- ── Pre-flight visibility: how many chunks are ALREADY past the 90d horizon?
  -- On a young tenant this is 0 (install is inert). A non-zero value here means
  -- the retention job WILL drop those chunks on its next run — so the operator
  -- MUST have confirmed the historian covers them first (see SAFETY above).
  SELECT count(*) INTO n_over_horizon
    FROM timescaledb_information.chunks
   WHERE hypertable_schema='public' AND hypertable_name='equipment_values'
     AND range_end < now() - hot_window;
  RAISE NOTICE 'equipment_values: % chunk(s) already older than the 90d horizon (0 = inert install)', n_over_horizon;

  -- ── 1. Compression: keep columnstore enabled; tighten policy 14d → 7d ──────
  BEGIN
    EXECUTE $$ALTER TABLE public.equipment_values SET (
                timescaledb.compress,
                timescaledb.compress_segmentby = 'id_equipment',
                timescaledb.compress_orderby   = 'ts_value DESC')$$;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'equipment_values: compress settings already in place (%), leaving as-is', SQLERRM;
  END;
  -- remove-then-add so a pre-existing 14d policy converges to 7d
  PERFORM remove_compression_policy('public.equipment_values', if_exists => true);
  PERFORM add_compression_policy('public.equipment_values', compress_after => compress_after, if_not_exists => true);
  RAISE NOTICE 'equipment_values: compress_after → %', compress_after;

  -- ── 2. Retention: 2y/180d → 90d (remove-then-add converges the horizon) ────
  PERFORM remove_retention_policy('public.equipment_values', if_exists => true);
  PERFORM add_retention_policy('public.equipment_values', drop_after => hot_window, if_not_exists => true);
  RAISE NOTICE 'equipment_values: retention drop_after → % (historian-backed cold tier)', hot_window;
END
$tier$;

-- ── VERIFY (prints resulting policy set for equipment_values) ─────────────────
\echo '=== equipment_values policies after tiering (expect compress 7d + retention 90d) ==='
SELECT job_id, proc_name, hypertable_name, schedule_interval, config
  FROM timescaledb_information.jobs
 WHERE proc_name IN ('policy_retention','policy_compression')
   AND hypertable_name = 'equipment_values'
 ORDER BY proc_name;

\echo '=== sibling raw/agg tables left UNCHANGED (sanity: events/lab keep long retention) ==='
SELECT job_id, proc_name, hypertable_name, config
  FROM timescaledb_information.jobs
 WHERE proc_name = 'policy_retention'
   AND hypertable_name <> 'equipment_values'
 ORDER BY hypertable_name;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK (restore 0036-b0 pre-tiering state: 2y retention + 14d compress).
-- ═══════════════════════════════════════════════════════════════════════════
-- DO $rollback$
-- BEGIN
--   IF to_regclass('public.equipment_values') IS NOT NULL THEN
--     PERFORM remove_compression_policy('public.equipment_values', if_exists => true);
--     PERFORM add_compression_policy('public.equipment_values', compress_after => INTERVAL '14 days', if_not_exists => true);
--     PERFORM remove_retention_policy('public.equipment_values', if_exists => true);
--     PERFORM add_retention_policy('public.equipment_values', drop_after => INTERVAL '2 years', if_not_exists => true);
--   END IF;
-- END
-- $rollback$;
