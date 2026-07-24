-- 0036-b1-bronze-raw-append.sql
-- ADR-0036 §3.6 — B1: append-only Bronze (`equipment_values_raw` /
-- `equipment_events_raw`). Logical migration `db/42` (the T0-2 temporal
-- columns `ingested_at`/`source_seq` are logical `db/41` — §5A; this file
-- carries them explicitly on the *_raw tables so it stands alone even where
-- db/41 has not yet landed on the base tables).
--
-- WHY a SEPARATE table and not an in-place change to equipment_values:
--   The live `equipment_values` UPSERT (`ON CONFLICT (ts_value, id_equipment)
--   DO UPDATE ... COALESCE`) is a load-bearing COLUMN-MERGE, not dedup — it
--   fuses the five metric kinds (net/gross/scrap/state/mode) into one wide
--   `(minute, equipment)` row the `agg_*` rollup views GROUP BY. Making it
--   append-only in place would scatter counters into the `mode = NULL` group
--   and silently break the Gold rollup contract (§3.6.1). Bronze is therefore
--   its OWN append-only hypertable, fed ALONGSIDE the untouched operational
--   table by a default-OFF dual-write (BRONZE_RAW_APPEND — §3.6.3).
--
-- KEY: (id_equipment, ts_value, source_seq). `source_seq` is a writer-assigned
--   monotonic tiebreak that lets two same-(equipment, ts_value) samples COEXIST
--   instead of colliding — resolving the sub-second overwrite of ADR-0037 (g)
--   *by construction*. `ts_value` (partition col) is IN the key → valid
--   hypertable unique constraint.
--
-- RETENTION (R1 directive — compress-to-years, NO hard drop): Bronze is the
--   REPLAY SOURCE OF TRUTH (§3.3), so it is NEVER hard-dropped. We add a
--   COMPRESSION policy (columnstore after a warm window) for historian-class
--   density, and DELIBERATELY DO NOT add a retention `drop_after` policy. This
--   refines the illustrative 2-year `drop` in §3.6.2: the whole point of Bronze
--   is that raw outlives the operational window so history can be reprocessed.
--
-- Idempotent (IF NOT EXISTS / if_not_exists guards + a constraint-existence DO
-- block) and reversible (see the DOWN block at the foot of this file).
-- BUILD-AND-PROVE only — the dual-write ships flag-OFF; the read-cutover that
-- retires the merge is gated post-ADR-0032 F2 collapse (§3.6.5).

BEGIN;

-- ── equipment_values_raw ────────────────────────────────────────────────────
-- LIKE the operational table so every decoded-sample column is captured 1:1.
CREATE TABLE IF NOT EXISTS equipment_values_raw
    (LIKE equipment_values INCLUDING DEFAULTS);

-- Lineage columns (§5A). Guarded by a column-existence check (not a bare
-- ADD ... IF NOT EXISTS) DELIBERATELY: TimescaleDB rejects `ADD COLUMN` with a
-- volatile default (now()) on a columnstore-enabled hypertable at PARSE time,
-- BEFORE the IF-NOT-EXISTS short-circuit runs — so a re-run (table already
-- compressed) would error. A DO block never plans the ALTER when the column
-- already exists, so this is genuinely idempotent AND the first run adds the
-- columns while the table is still uncompressed (compression is enabled below).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'equipment_values_raw' AND column_name = 'ingested_at') THEN
        ALTER TABLE equipment_values_raw ADD COLUMN ingested_at TIMESTAMPTZ NOT NULL DEFAULT now();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'equipment_values_raw' AND column_name = 'source_seq') THEN
        ALTER TABLE equipment_values_raw ADD COLUMN source_seq BIGINT NOT NULL DEFAULT 0;
    END IF;
END $$;

-- Append-only PK that ADMITS every raw sample (source_seq tiebreak). Guarded so
-- a re-run does not error on the already-present constraint.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'equipment_values_raw_pkey'
    ) THEN
        ALTER TABLE equipment_values_raw
            ADD CONSTRAINT equipment_values_raw_pkey
            PRIMARY KEY (id_equipment, ts_value, source_seq);
    END IF;
END $$;

SELECT create_hypertable('equipment_values_raw', 'ts_value', if_not_exists => TRUE);

-- Columnstore compression (B0 economics — segment by equipment, order by the
-- full key so decompressed scans stay ordered for range reads + the source_seq
-- tiebreak). Safe to re-run: SET is declarative.
ALTER TABLE equipment_values_raw SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'id_equipment',
    timescaledb.compress_orderby   = 'ts_value DESC, source_seq DESC'
);
SELECT add_compression_policy('equipment_values_raw',
    compress_after => INTERVAL '7 days', if_not_exists => TRUE);
-- NO add_retention_policy: Bronze is the replay source of truth — never hard-dropped.

-- ── equipment_events_raw ────────────────────────────────────────────────────
-- Partitioned on ts_event; PK (id_equipment, ts_event, source_seq). Note the
-- operational equipment_events carries a BIGSERIAL id_equipment_event surrogate
-- PK on some deployments; LIKE copies the column but NOT the PK/serial identity
-- (INCLUDING DEFAULTS excludes constraints), so the append-only PK below is the
-- only key on *_raw — exactly what Bronze wants.
CREATE TABLE IF NOT EXISTS equipment_events_raw
    (LIKE equipment_events INCLUDING DEFAULTS);

-- Drop any id_equipment_event column copied from the operational table: on
-- *_raw it is neither the key nor populated by the append-only writer. Done
-- BEFORE compression so no columnstore restriction applies; IF EXISTS = no-op
-- on re-run.
ALTER TABLE equipment_events_raw DROP COLUMN IF EXISTS id_equipment_event;

-- Lineage columns — same columnstore-safe DO-block guard as the values table.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'equipment_events_raw' AND column_name = 'ingested_at') THEN
        ALTER TABLE equipment_events_raw ADD COLUMN ingested_at TIMESTAMPTZ NOT NULL DEFAULT now();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'equipment_events_raw' AND column_name = 'source_seq') THEN
        ALTER TABLE equipment_events_raw ADD COLUMN source_seq BIGINT NOT NULL DEFAULT 0;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'equipment_events_raw_pkey'
    ) THEN
        ALTER TABLE equipment_events_raw
            ADD CONSTRAINT equipment_events_raw_pkey
            PRIMARY KEY (id_equipment, ts_event, source_seq);
    END IF;
END $$;

SELECT create_hypertable('equipment_events_raw', 'ts_event', if_not_exists => TRUE);

ALTER TABLE equipment_events_raw SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'id_equipment',
    timescaledb.compress_orderby   = 'ts_event DESC, source_seq DESC'
);
SELECT add_compression_policy('equipment_events_raw',
    compress_after => INTERVAL '7 days', if_not_exists => TRUE);
-- NO add_retention_policy: same historian-horizon rationale.

COMMIT;

-- ── DOWN (reversible) ───────────────────────────────────────────────────────
-- Bronze is purely additive; nothing reads *_raw yet, so the down path is a
-- clean drop (which also drops the compression policies). Run to revert:
--
--   BEGIN;
--   DROP TABLE IF EXISTS equipment_values_raw;
--   DROP TABLE IF EXISTS equipment_events_raw;
--   COMMIT;
