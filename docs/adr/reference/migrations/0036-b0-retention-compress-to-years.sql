-- 0036-b0-retention-compress-to-years.sql — ADR-0036 §3.5 "DECISION — B0 (refined)",
-- medallion recommendation R1. AS-EXECUTED on staging packiot_shadow (F3) +
-- packiot (F1) 2026-07-23.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHY THIS EXISTS — stop the Bronze historian destroying its own replay source.
-- ═══════════════════════════════════════════════════════════════════════════
-- Live-DB audit (2026-07-23, packiot_shadow) found TimescaleDB retention jobs
--   1002  policy_retention  equipment_values  drop_after '180 days'
--   1012  policy_retention  equipment_events  drop_after '180 days'
-- that HARD-DROP raw older than ~6 months. These policies lived ONLY in the live
-- DB (config drift — invisible to version control). They directly contradict the
-- medallion premise (ADR-0036 §3.1/§3.3): Bronze is the multi-year, immutable
-- REPROCESSING source of truth. A 180-day rolling DROP silently deletes exactly
-- the history every ADR-0037 Silver/Gold fix needs to replay over. This migration
-- (a) moves retention into version control and (b) converts drop → compress-warm
-- + a years-long drop horizon so raw stays (compressed) for the historian window
-- and only truly-ancient data is dropped.
--
-- Compression is ALREADY live (14-day columnstore, jobs 1018/1019/1020, ~33x
-- ratio measured) — this migration does NOT touch compression; it only replaces
-- the retention (drop) horizon. It is defensive/idempotent about compression so
-- it is safe to run on a DB where compression was never configured.
--
-- ───────────────────────────────────────────────────────────────────────────
-- HORIZON CHOICE — 2 years.
-- ───────────────────────────────────────────────────────────────────────────
-- ADR-0036 §3.2 (line 185) and §3.5 "DECISION — B0" (line 235) both name the
-- historian horizon explicitly as INTERVAL '2 years'. We adopt the ADR value
-- verbatim rather than the §7 conservative-90-days fallback because the disk
-- headroom check (below) shows it costs almost nothing:
--   staging DB EC2 i-064bb36d1c454d861  /  = 64G, 29G used, 36G free (44%).
--   packiot_shadow.equipment_values     = 947 MB total, 4.5 MB compressed heap.
--   packiot_shadow.equipment_events     = 12 MB total,  424 kB compressed heap.
--   packiot.equipment_values (F1)       = 3423 MB total, 173 MB compressed heap.
--   packiot.equipment_events (F1)       = 469 MB total,  18 MB compressed heap.
-- At the measured ~33x columnstore ratio, 2 years of cold raw is on the order of
-- ~1 GB compressed even for F1 — trivially inside the 36 GB free. The §7
-- 90-day-on-undersized-hardware caution does not bind here: 90d would barely
-- improve on the 180d we are REMOVING and would defeat R1's whole purpose.
-- Prod (SELECT-only for us) applies this under the normal prod-apply gate (§6 P),
-- where the horizon may be re-sized to prod volume before apply.
--
-- ───────────────────────────────────────────────────────────────────────────
-- SCOPE — which DBs / tables.
-- ───────────────────────────────────────────────────────────────────────────
-- Run this file on:
--   • packiot_shadow (F3, PRIMARY — the medallion Bronze source of truth):
--       R1  public.equipment_values, public.equipment_events   (drop 180d → 2y)
--       R1b public.lab_equipment_values  (compresses via job 1020 but had NO
--           retention at all — the opposite inconsistency; give it a conscious
--           1-year horizon, guarded so it is a no-op where the table is absent).
--   • packiot (F1, legacy flow still live on staging): carries the identical
--       180d drop on public.{equipment_values,equipment_events} → apply R1 for
--       consistency. It has NO public.lab_equipment_values, so the R1b block is
--       a guarded no-op there.
-- Deliberately OUT OF SCOPE (documented, not touched here):
--   • packiot_refactor (F2): has NO retention/compression jobs at all and no
--       public.equipment_events hypertable — nothing dangerous to fix; dormant.
--       This file is idempotent, so running it there is harmless (removes touch
--       nothing; adds are guarded), but we do not actively apply it to F2.
--   • packiot schema `shadow_go_port` (defunct Go-port shadow: shadow_go_port.
--       equipment_values / _events, retention job 1015): leftover of a retired
--       port. Not the operational Bronze. Retire the whole schema separately.
--
-- ───────────────────────────────────────────────────────────────────────────
-- IDEMPOTENCY / REVERSIBILITY.
-- ───────────────────────────────────────────────────────────────────────────
-- • remove_retention_policy(..., if_exists => true) never errors if absent.
-- • add_retention_policy(..., if_not_exists => true) is a no-op if an identical
--   policy already exists; but because we want to CHANGE the horizon, we always
--   remove-then-add so re-runs converge on 2y regardless of prior drop_after.
-- • Compression is (re)asserted defensively with IF-guards; if the 14d columnstore
--   policy is already present (jobs 1018/1019/1020) it is left as-is.
-- • ROLLBACK (documented, at the very bottom, commented out): re-add the 180-day
--   drop and drop the lab retention — restores the exact pre-migration policy set.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

DO $r1$
DECLARE
  -- Historian horizon (ADR-0036 §3.5 B0). Change here to re-size per DB volume.
  bronze_drop_after CONSTANT interval := INTERVAL '2 years';
  lab_drop_after    CONSTANT interval := INTERVAL '1 year';   -- R1b conscious horizon
  compress_after    CONSTANT interval := INTERVAL '14 days';  -- keep existing warm window
BEGIN
  -- ── R1: equipment_values ──────────────────────────────────────────────────
  IF to_regclass('public.equipment_values') IS NOT NULL THEN
    -- keep warm-compression (assert columnstore + 14d policy defensively)
    BEGIN
      EXECUTE $$ALTER TABLE public.equipment_values SET (
                  timescaledb.compress,
                  timescaledb.compress_segmentby = 'id_equipment',
                  timescaledb.compress_orderby   = 'ts_value DESC')$$;
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'equipment_values: compress settings already in place / not alterable (%), leaving as-is', SQLERRM;
    END;
    PERFORM add_compression_policy('public.equipment_values', compress_after => compress_after, if_not_exists => true);

    -- drop the 180d DROP, install the 2y DROP (remove-then-add => converges to 2y)
    PERFORM remove_retention_policy('public.equipment_values', if_exists => true);
    PERFORM add_retention_policy('public.equipment_values', drop_after => bronze_drop_after, if_not_exists => true);
    RAISE NOTICE 'R1  equipment_values      → drop_after=%', bronze_drop_after;
  ELSE
    RAISE NOTICE 'R1  equipment_values      → absent, skipped';
  END IF;

  -- ── R1: equipment_events ──────────────────────────────────────────────────
  IF to_regclass('public.equipment_events') IS NOT NULL THEN
    BEGIN
      EXECUTE $$ALTER TABLE public.equipment_events SET (
                  timescaledb.compress,
                  timescaledb.compress_segmentby = 'id_equipment',
                  timescaledb.compress_orderby   = 'ts_event DESC')$$;
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'equipment_events: compress settings already in place / not alterable (%), leaving as-is', SQLERRM;
    END;
    PERFORM add_compression_policy('public.equipment_events', compress_after => compress_after, if_not_exists => true);

    PERFORM remove_retention_policy('public.equipment_events', if_exists => true);
    PERFORM add_retention_policy('public.equipment_events', drop_after => bronze_drop_after, if_not_exists => true);
    RAISE NOTICE 'R1  equipment_events      → drop_after=%', bronze_drop_after;
  ELSE
    RAISE NOTICE 'R1  equipment_events      → absent, skipped';
  END IF;

  -- ── R1b: lab_equipment_values (had compression job 1020 but NO retention) ──
  IF to_regclass('public.lab_equipment_values') IS NOT NULL THEN
    PERFORM remove_retention_policy('public.lab_equipment_values', if_exists => true);
    PERFORM add_retention_policy('public.lab_equipment_values', drop_after => lab_drop_after, if_not_exists => true);
    RAISE NOTICE 'R1b lab_equipment_values  → drop_after=% (was: unbounded)', lab_drop_after;
  ELSE
    RAISE NOTICE 'R1b lab_equipment_values  → absent, skipped';
  END IF;
END
$r1$;

-- ── VERIFY (prints resulting policy set; safe to keep in the migration) ───────
SELECT job_id, proc_name, hypertable_name, config
FROM timescaledb_information.jobs
WHERE proc_name IN ('policy_retention','policy_compression')
  AND hypertable_name IN ('equipment_values','equipment_events','lab_equipment_values')
ORDER BY hypertable_name, proc_name, job_id;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK (documented — restores the exact pre-migration policy set).
-- Run only to revert; re-adds the 180-day DROP and removes the lab retention.
-- ═══════════════════════════════════════════════════════════════════════════
-- DO $rollback$
-- BEGIN
--   IF to_regclass('public.equipment_values') IS NOT NULL THEN
--     PERFORM remove_retention_policy('public.equipment_values', if_exists => true);
--     PERFORM add_retention_policy('public.equipment_values', drop_after => INTERVAL '180 days', if_not_exists => true);
--   END IF;
--   IF to_regclass('public.equipment_events') IS NOT NULL THEN
--     PERFORM remove_retention_policy('public.equipment_events', if_exists => true);
--     PERFORM add_retention_policy('public.equipment_events', drop_after => INTERVAL '180 days', if_not_exists => true);
--   END IF;
--   -- R1b was NET-NEW (lab had no retention before) → rollback REMOVES it:
--   IF to_regclass('public.lab_equipment_values') IS NOT NULL THEN
--     PERFORM remove_retention_policy('public.lab_equipment_values', if_exists => true);
--   END IF;
-- END
-- $rollback$;
