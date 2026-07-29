-- 0036-b1-bronze-raw-immutability.sql — ADR-0036 §3 medallion recommendation B1.
-- Makes the Bronze landing zone (equipment_values_raw / equipment_events_raw)
-- APPEND-ONLY and gives it the same multi-year retention horizon B0 gave the
-- operational fact tables. AS-EXECUTED on staging packiot_shadow (F3).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHY THIS EXISTS — Bronze must be the immutable, replayable source of truth.
-- ═══════════════════════════════════════════════════════════════════════════
-- ADR-0036 §3.1/§3.3: Bronze is the raw historian every Silver/Gold correction
-- replays over. That guarantee is only real if the raw rows can never be edited
-- or deleted in place — a "correction" is a NEW appended row (carrying its own
-- source_seq), never an UPDATE/DELETE of history.
--
-- THE LOAD-BEARING FACT — REVOKE is silently useless here.
-- The oeecloud-worker DB writer connects as a SUPERUSER (postgres). Superusers
-- bypass table privileges, so `REVOKE UPDATE, DELETE ... FROM ...` does NOTHING
-- against it. The ONLY enforcement that binds a superuser is a row-level trigger
-- that RAISEs. So immutability is a `BEFORE UPDATE OR DELETE ... FOR EACH ROW`
-- trigger (copied verbatim in spirit from the existing box_scans_no_mutate
-- pattern, 00-packiot_shadow-schema.sql:39), NOT a grant change.
--
-- SCOPE — the *_raw Bronze hypertables ONLY.
--   public.equipment_values_raw   (PK id_equipment, ts_value, source_seq)
--   public.equipment_events_raw   (PK id_equipment, ts_event, source_seq)
-- DELIBERATELY NOT TOUCHED (they are operational/Silver, NOT Bronze — putting a
-- no_mutate trigger on them would break the live pipeline):
--   • public.equipment_values  — its per-second column-merge UPSERT (ON CONFLICT
--       DO UPDATE) is load-bearing; blocking UPDATE would kill ingest.
--   • public.equipment_events  — the ADR-0014 deriver DELETEs/re-INSERTs interval
--       rows and pocontrol enriches reasons; both require UPDATE/DELETE.
--
-- ───────────────────────────────────────────────────────────────────────────
-- RETENTION vs the no_mutate trigger — WHY THEY DO NOT COLLIDE.
-- ───────────────────────────────────────────────────────────────────────────
-- add_retention_policy runs drop_chunks(), which DROPs whole chunk sub-tables
-- via DDL (DROP TABLE on _timescaledb_internal._hyper_*_chunk). It does NOT issue
-- a row-level `DELETE FROM ...`. A `FOR EACH ROW` BEFORE DELETE trigger only fires
-- on row-level DML, so retention chunk-drops are UNAFFECTED by the guard. Verified
-- live (see the drop_chunks smoke test in the apply report). This is the same
-- reason TimescaleDB compression (which rewrites chunks via DDL) is unaffected.
--
-- Horizon = INTERVAL '2 years' — identical to B0 (0036-b0-retention-compress-to-
-- years.sql). Bronze at ~33x columnstore is ~1 GB compressed even for F1 volume,
-- trivially inside the staging DB's free space (see B0 header disk math).
--
-- ───────────────────────────────────────────────────────────────────────────
-- IDEMPOTENCY / REVERSIBILITY.
-- ───────────────────────────────────────────────────────────────────────────
-- • CREATE OR REPLACE FUNCTION — re-runnable.
-- • DROP TRIGGER IF EXISTS then CREATE TRIGGER — re-runnable (CREATE TRIGGER has
--   no IF NOT EXISTS on PG15, so drop-then-create is the portable idempotent form).
-- • remove_retention_policy(if_exists) + add_retention_policy(if_not_exists),
--   remove-then-add so a re-run converges on 2y regardless of any prior horizon.
-- • Compression is (re)asserted defensively behind an EXCEPTION guard — a no-op
--   where the 14-day columnstore is already configured (it already is on staging).
-- • ROLLBACK documented (commented) at the bottom: drop the two triggers + the
--   function, and drop the _raw retention — restores the pre-migration state.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ── B1.1  append-only guard function ─────────────────────────────────────────
-- One shared trigger fn for both Bronze hypertables. restrict_violation (ERRCODE
-- 2F004-family) is the same class box_scans_no_mutate raises; the message names
-- the table + the attempted op and points the operator at the correction model.
CREATE OR REPLACE FUNCTION public.bronze_raw_no_mutate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION
        'Bronze raw table %.% is append-only (attempted %); corrections are new appended rows, never in-place edits',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$;

-- ── B1.2  attach the guard to the two *_raw Bronze hypertables ────────────────
DROP TRIGGER IF EXISTS trg_equipment_values_raw_no_mutate ON public.equipment_values_raw;
CREATE TRIGGER trg_equipment_values_raw_no_mutate
    BEFORE UPDATE OR DELETE ON public.equipment_values_raw
    FOR EACH ROW EXECUTE FUNCTION public.bronze_raw_no_mutate();

DROP TRIGGER IF EXISTS trg_equipment_events_raw_no_mutate ON public.equipment_events_raw;
CREATE TRIGGER trg_equipment_events_raw_no_mutate
    BEFORE UPDATE OR DELETE ON public.equipment_events_raw
    FOR EACH ROW EXECUTE FUNCTION public.bronze_raw_no_mutate();

-- ── B1.3  2-year retention on the _raw hypertables ───────────────────────────
-- Compression is DELIBERATELY NOT touched here: the _raw hypertables already carry
-- a 14-day-warm columnstore on staging (segmentby id_equipment, orderby ts DESC +
-- source_seq DESC, jobs 1027/1028) — re-asserting it would risk rewriting that
-- known-good orderby. Compression for a FRESH F3 bootstrap is set up (matching this
-- config) in db/init-f3/snapshot/10-f3-timescale-supplement.sql. Here we only ADD
-- the missing retention (there is none on _raw yet — audited 2026-07-29).
DO $b1$
DECLARE
  bronze_drop_after CONSTANT interval := INTERVAL '2 years';  -- ADR-0036 §3.5, == B0
BEGIN
  IF to_regclass('public.equipment_values_raw') IS NOT NULL THEN
    PERFORM remove_retention_policy('public.equipment_values_raw', if_exists => true);
    PERFORM add_retention_policy('public.equipment_values_raw', drop_after => bronze_drop_after, if_not_exists => true);
    RAISE NOTICE 'B1  equipment_values_raw  → retention drop_after=%', bronze_drop_after;
  ELSE
    RAISE NOTICE 'B1  equipment_values_raw  → absent, skipped';
  END IF;

  IF to_regclass('public.equipment_events_raw') IS NOT NULL THEN
    PERFORM remove_retention_policy('public.equipment_events_raw', if_exists => true);
    PERFORM add_retention_policy('public.equipment_events_raw', drop_after => bronze_drop_after, if_not_exists => true);
    RAISE NOTICE 'B1  equipment_events_raw  → retention drop_after=%', bronze_drop_after;
  ELSE
    RAISE NOTICE 'B1  equipment_events_raw  → absent, skipped';
  END IF;
END
$b1$;

-- ── VERIFY (prints the resulting immutability + policy set; safe to keep) ──────
SELECT tgrelid::regclass AS bronze_table, tgname AS trigger_name,
       tgenabled AS enabled  -- 'O' = enabled in origin+local (fires for the superuser writer)
FROM pg_trigger
WHERE tgname IN ('trg_equipment_values_raw_no_mutate','trg_equipment_events_raw_no_mutate')
ORDER BY bronze_table;

SELECT job_id, proc_name, hypertable_name, config
FROM timescaledb_information.jobs
WHERE proc_name IN ('policy_retention','policy_compression')
  AND hypertable_name IN ('equipment_values_raw','equipment_events_raw')
ORDER BY hypertable_name, proc_name, job_id;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK (documented — restores the pre-migration state). Run only to revert.
-- ═══════════════════════════════════════════════════════════════════════════
-- DROP TRIGGER IF EXISTS trg_equipment_values_raw_no_mutate ON public.equipment_values_raw;
-- DROP TRIGGER IF EXISTS trg_equipment_events_raw_no_mutate ON public.equipment_events_raw;
-- DROP FUNCTION IF EXISTS public.bronze_raw_no_mutate();
-- SELECT remove_retention_policy('public.equipment_values_raw', if_exists => true);
-- SELECT remove_retention_policy('public.equipment_events_raw', if_exists => true);
-- -- (compression policy was pre-existing on staging; leave it — or remove with
-- --  remove_compression_policy(..., if_exists => true) if this migration added it.)
