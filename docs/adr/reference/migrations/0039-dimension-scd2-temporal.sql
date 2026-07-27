-- 0039-dimension-scd2-temporal.sql — R6 (medallion): lightweight SCD-2 /
-- temporal foundation on the core dimension tables.
-- ADR: 0039 (entity-lifecycle) · medallion recommendation R6 · complements
-- ADR-0036 §5A (which added lineage cols to FACTS: Bronze ingested_at/source_seq,
-- Gold computed_at/source_watermark).  This is the DIMENSION-side counterpart.
--
-- WHY:
--   Facts got lineage columns in ADR-0036 §5A, but DIMENSIONS still lack any
--   temporal history.  `equipments` carries only `active` (a soft-delete
--   boolean, SCD-1 overwrite-in-place) — it records neither WHEN nor WHAT-
--   CHANGED.  So the platform cannot answer "what was this equipment's config
--   (ideal_speed / id_area / nm_equipment) when that historical OEE was
--   computed?" — the genealogy join ADR-0038 pillar P7 needs.
--
-- SCOPE — LIGHTWEIGHT SCD-2 FOUNDATION (columns + updated_at trigger), NOT the
-- full Tier-2 `*_history` machinery:
--   * Add valid_from / valid_to / created_at / updated_at to the core
--     dimensions: equipments, sites, areas, enterprises.
--   * Probed SELECT-only on packiot_shadow (2026-07-23): NONE of the four
--     tables carry any created/updated/valid_* column today, so there is no
--     pre-existing created timestamp to backfill from -> valid_from/created_at
--     backfill to now() (the ADD COLUMN DEFAULT).
--   * An updated_at BEFORE-UPDATE trigger keeps updated_at current.
--   * A full SCD-2 history/audit table (`*_history`, trigger-written versions)
--     is a NOTED FOLLOW-UP (ADR-0039 Tier-2, lands with the Traceability
--     pillar 0038 Phase-B3) — deliberately deferred: it is the highest-cost
--     tier and has no reader yet.  This migration lays only the column
--     foundation those history rows will version.
--
-- Column-naming is aligned across 0036 (facts) and 0039 (dimensions):
-- valid_from/valid_to = the SCD-2 validity interval; created_at/updated_at =
-- mutation stamps.
--
-- SAFETY: additive DDL only; fully reversible (DROP the 4 columns per table +
-- the triggers).  Idempotent (ADD COLUMN IF NOT EXISTS; DROP TRIGGER IF EXISTS
-- before CREATE).  set_updated_at() is created in 0039-reasons-dimension.sql
-- (applied first); re-created here CREATE-OR-REPLACE so this file is
-- self-contained.  Staging first; prod applies under the standing prod gate.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- shared updated_at trigger fn (idempotent; also created by the R5 migration)
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ── equipments ────────────────────────────────────────────────────────────
ALTER TABLE equipments  ADD COLUMN IF NOT EXISTS valid_from timestamptz NOT NULL DEFAULT now();
ALTER TABLE equipments  ADD COLUMN IF NOT EXISTS valid_to   timestamptz;
ALTER TABLE equipments  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE equipments  ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- ── sites ─────────────────────────────────────────────────────────────────
ALTER TABLE sites       ADD COLUMN IF NOT EXISTS valid_from timestamptz NOT NULL DEFAULT now();
ALTER TABLE sites       ADD COLUMN IF NOT EXISTS valid_to   timestamptz;
ALTER TABLE sites       ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE sites       ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- ── areas ─────────────────────────────────────────────────────────────────
ALTER TABLE areas       ADD COLUMN IF NOT EXISTS valid_from timestamptz NOT NULL DEFAULT now();
ALTER TABLE areas       ADD COLUMN IF NOT EXISTS valid_to   timestamptz;
ALTER TABLE areas       ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE areas       ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- ── enterprises ───────────────────────────────────────────────────────────
ALTER TABLE enterprises ADD COLUMN IF NOT EXISTS valid_from timestamptz NOT NULL DEFAULT now();
ALTER TABLE enterprises ADD COLUMN IF NOT EXISTS valid_to   timestamptz;
ALTER TABLE enterprises ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE enterprises ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- ── updated_at triggers ─────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_set_updated_at ON equipments;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON equipments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS trg_set_updated_at ON sites;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON sites
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS trg_set_updated_at ON areas;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON areas
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS trg_set_updated_at ON enterprises;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON enterprises
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;

-- ── verification (read-only) — expected: 4 temporal cols present on each of
--   equipments/sites/areas/enterprises; valid_from & created_at NOT NULL and
--   backfilled to the apply timestamp; valid_to & updated_at NULL.
-- SELECT table_name, count(*) FILTER (WHERE column_name IN
--   ('valid_from','valid_to','created_at','updated_at')) AS temporal_cols
-- FROM information_schema.columns
-- WHERE table_name IN ('equipments','sites','areas','enterprises')
-- GROUP BY table_name ORDER BY table_name;
