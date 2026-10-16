-- 05-oee-silver-runtime-hardening.sql — REFACTORED schemas only
-- (F3 public in packiot_analytics; F2 shadow_go_port in packiot). NEVER legacy packiot.public.
--
-- Two low-risk, reversible hardening passes on the small, high-churn OEE Silver
-- rollup tables, from an approved DBA review. Sed-replace __SCH__ per schema.
-- Idempotent: safe to re-run. Everything here is fully reversible (ALTER ...
-- RESET (...) / DROP CONSTRAINT). The CONCURRENTLY index prune + VACUUM FULL live
-- in the sibling out-of-transaction script 06-eqvalues-index-prune.MANUAL.sql
-- (those statements cannot run inside a migration transaction).
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PASS A — per-size autovacuum + fillfactor on the small rollups
-- ─────────────────────────────────────────────────────────────────────────────
-- These tables inherited a one-size-fits-all reloption set
-- (autovacuum_vacuum_threshold=5000, scale_factor=0.02). For a 1k–16k-row table
-- that threshold is never reached: e.g. area_runtime_shift (1122 live rows) needs
-- 5000 + 0.02*1122 ≈ 5022 dead tuples before autovacuum fires, so it sat at
-- 68.9% dead (2486 dead / 3608 total) on staging; equipment_runtime_1day sat at
-- 39.2%. These are UPDATE-heavy tables (recalc_needed flips + OEE recompute
-- rewrite whole rows), so bloat accumulates fast.
--
-- Fix: low absolute thresholds sized to each table so autovacuum tracks real
-- churn, plus a fillfactor that leaves free space per page for HOT (heap-only
-- tuple) updates — an UPDATE that fits on the same page skips index maintenance
-- and reduces index bloat. 1hour is larger + already low-dead, so it only takes
-- a gentler fillfactor and keeps its existing autovacuum cadence.
--
-- Reversible: ALTER TABLE ... RESET (autovacuum_vacuum_threshold,
-- autovacuum_vacuum_scale_factor, autovacuum_analyze_threshold,
-- autovacuum_analyze_scale_factor, fillfactor);

ALTER TABLE IF EXISTS __SCH__.area_runtime_shift        SET (autovacuum_vacuum_threshold=50,  autovacuum_vacuum_scale_factor=0.05, autovacuum_analyze_threshold=50,  autovacuum_analyze_scale_factor=0.05, fillfactor=85);
ALTER TABLE IF EXISTS __SCH__.equipment_runtime_shift   SET (autovacuum_vacuum_threshold=100, autovacuum_vacuum_scale_factor=0.05, autovacuum_analyze_threshold=100, autovacuum_analyze_scale_factor=0.05, fillfactor=85);
ALTER TABLE IF EXISTS __SCH__.equipment_runtime_1day    SET (autovacuum_vacuum_threshold=100, autovacuum_vacuum_scale_factor=0.05, autovacuum_analyze_threshold=100, autovacuum_analyze_scale_factor=0.05, fillfactor=85);
ALTER TABLE IF EXISTS __SCH__.production_orders_runtime SET (autovacuum_vacuum_threshold=200, autovacuum_vacuum_scale_factor=0.05, autovacuum_analyze_threshold=200, autovacuum_analyze_scale_factor=0.05, fillfactor=85);
-- 1hour: larger (~49 MB, 100k rows), already ~0.2% dead — fillfactor only, keep cadence.
ALTER TABLE IF EXISTS __SCH__.equipment_runtime_1hour   SET (fillfactor=90);

-- ─────────────────────────────────────────────────────────────────────────────
-- PASS B — OEE Silver CHECK constraints (self-guarding)
-- ─────────────────────────────────────────────────────────────────────────────
-- Goal of the review: add data-quality CHECK constraints on the runtime tables
-- (oee/oee_a/oee_p/oee_q BETWEEN 0 AND 1; net <= gross; non-negativity;
-- ts_value <= ts_end). Reality check on staging FALSIFIED the "0 violations"
-- premise for the *value* constraints — the OEE engine currently emits grossly
-- out-of-range Silver rows, e.g.:
--
--   equipment_runtime_1hour : oee up to 13918, oee_q up to 1.78
--   area_runtime_shift      : oee up to 1161, oee_a up to 2342, oee_q up to 3
--   site_runtime_shift      : oee up to 6084, oee_a up to 38316
--   production_orders_runtime: oee_q up to 25305
--   net > gross present on EVERY table (112/62/18/745/42/53 rows; gap up to 68440)
--   a handful of negative available_time/ideal_production/gross/net rows
--
-- Adding a hard CHECK to these live-written tables would break the OEE ingest
-- path the next time the engine emits such a row — that is an availability risk,
-- not a "reversible/low" change. Those value constraints are therefore DEFERRED
-- until the engine's OEE rollup math is fixed/clamped (see PR body — data-quality
-- finding). Templates kept below, commented out, for when the data is clean.
--
-- What we DO add here: ts_value <= ts_end on the *_shift tables. This is a
-- structural shift-calendar invariant (interval end >= start), independent of the
-- OEE math, and had 0 violations across all shift rows on staging. The DO block
-- re-proves 0 violations at apply time and self-skips (NOTICE) on any schema
-- whose data would violate it — so it is safe to run against F2 and F3 alike.
--
-- Reversible: ALTER TABLE __SCH__.<table> DROP CONSTRAINT chk_<table>_ts_order;

DO $$
DECLARE
    v_sch text := '__SCH__';
    t     text;
    n_bad bigint;
    cname text;
BEGIN
    FOREACH t IN ARRAY ARRAY['equipment_runtime_shift','area_runtime_shift','site_runtime_shift']
    LOOP
        -- table + both columns must exist in this schema
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema=v_sch AND table_name=t AND column_name='ts_end') THEN
            RAISE NOTICE 'skip %.% (no ts_end)', v_sch, t; CONTINUE;
        END IF;

        cname := 'chk_'||t||'_ts_order';
        IF EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname=cname AND conrelid=(v_sch||'.'||t)::regclass) THEN
            RAISE NOTICE 'skip %.% (% already present)', v_sch, t, cname; CONTINUE;
        END IF;

        EXECUTE format('SELECT count(*) FROM %I.%I WHERE ts_value > ts_end', v_sch, t) INTO n_bad;
        IF n_bad <> 0 THEN
            RAISE NOTICE 'skip %.% — % rows violate ts_value <= ts_end (data not clean)', v_sch, t, n_bad;
            CONTINUE;
        END IF;

        EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (ts_value <= ts_end) NOT VALID',
                       v_sch, t, cname);
        EXECUTE format('ALTER TABLE %I.%I VALIDATE CONSTRAINT %I', v_sch, t, cname);
        RAISE NOTICE 'added + validated % on %.%', cname, v_sch, t;
    END LOOP;
END $$;

-- ── DEFERRED value constraints (re-enable per table only after a 0-violation
-- ── proof; the OEE engine must stop emitting out-of-range rows first) ─────────
-- ALTER TABLE __SCH__.equipment_runtime_shift ADD CONSTRAINT chk_equipment_runtime_shift_oee_range
--   CHECK (oee BETWEEN 0 AND 1 AND oee_a BETWEEN 0 AND 1 AND oee_p BETWEEN 0 AND 1 AND oee_q BETWEEN 0 AND 1) NOT VALID;
-- ALTER TABLE __SCH__.equipment_runtime_shift ADD CONSTRAINT chk_equipment_runtime_shift_net_le_gross
--   CHECK (net <= gross) NOT VALID;
-- ALTER TABLE __SCH__.equipment_runtime_shift ADD CONSTRAINT chk_equipment_runtime_shift_nonneg
--   CHECK (available_time >= 0 AND ideal_production >= 0 AND gross >= 0 AND net >= 0) NOT VALID;
-- (production_orders_runtime uses net_production/gross_production instead of net/gross.)
