-- 0039-reasons-dimension.sql — R5 (medallion): normalize downtime_reasons /
-- scrap_reasons OFF the `equipments` dimension into first-class reason
-- dimension + junction tables with FK'd codes.  EXPAND phase only.
-- ADR: 0039 (entity-lifecycle) · medallion recommendation R5 · FK-restoration theme #34.
--
-- WHY (the NF violation this fixes):
--   `equipments.downtime_reasons` / `scrap_reasons` are inline JSONB ARRAYS —
--   a repeating group (1NF violation) whose elements are their own entity
--   (a reason) sitting in a non-key column (3NF violation).  With no
--   dimension table and no FK on the codes, a reason rename touches every
--   equipment row, codes diverge/typo across equipment, orphans accrue, and
--   the vocabulary drifts across tenants.
--
-- LIVE SHAPE DRIVING THIS DESIGN (probed SELECT-only on packiot_shadow,
-- 2026-07-23):
--   * downtime_reasons is a 3-level nested jsonb array:
--       top-level  { "code": <machine name>, "categories": [ ... ] }
--                    ^ per-machine ATTRIBUTION grouping (which member machine
--                      caused a line stop) — NOT part of the reason vocabulary
--       category   { "code", "description": {"en-US": ...},
--                    "planned_downtime", "change_over", "idle",
--                    "subcategories": [ ... ] }
--       subcategory{ "code", "description": {...},
--                    "planned_downtime", "change_over", "idle" }
--   * The reason VOCABULARY (category + subcategory) is SHARED: the same 5
--     category codes + 13 subcategory codes appear on all 66 equipment that
--     carry downtime_reasons — a global (per-tenant) dimension, not
--     per-equipment.  66 equip span enterprises {1:1, 2:3, 3:62}.
--   * scrap_reasons is present as a jsonb column on every row but is 100%
--     EMPTY on staging (0 non-null).  The scrap dimension/junction are
--     created here MIRRORING the downtime shape (the sensible default) and
--     backfill to 0 rows — provisional until real scrap vocabulary lands.
--
-- DESIGN:
--   * A reason is the (category | subcategory) node.  Scoped by enterprise
--     (multitenancy — codes may legitimately collide across tenants; no
--     hardcoded enterprise ids).  Hierarchy captured by a self-referential
--     parent_id (subcategory -> category) + a denormalized `category` code
--     for convenience; `reason_level` 1=category 2=subcategory.
--   * The i18n label map is preserved WHOLE in label_i18n (no data loss);
--     `label` is the flattened en-US convenience string.
--   * The per-machine attribution grouping (top-level `code`) is PRESENTATION
--     metadata that stays in the jsonb during EXPAND; the junction records
--     the real many-to-many (equipment <-> reason vocabulary), flattening the
--     per-member repetition.
--   * Partial-unique WHERE active on (id_enterprise, code) — aligns with
--     ADR-0039 Tier-0b reactivation-friendly pattern.
--   * Temporal columns (valid_from/valid_to/created_at/updated_at) +
--     set_updated_at() trigger — aligned with R6 (0039-dimension-scd2-temporal.sql).
--
-- EXPAND ONLY: the equipments.downtime_reasons / scrap_reasons jsonb columns
-- are KEPT IN PLACE (dual-source during transition).  This migration does NOT
-- drop them and does NOT touch any consumer.  CONTRACT (drop the jsonb) is a
-- gated follow-up — see the consumer list in the PR body.
--
-- SAFETY: additive DDL only; fully reversible (DROP the 4 new tables +
-- set_updated_at()).  Idempotent (IF NOT EXISTS + ON CONFLICT DO NOTHING).
-- Applied to packiot_shadow (staging) first; prod applies under the standing
-- prod-apply gate.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── shared updated_at trigger fn (also used by R6; CREATE OR REPLACE = idempotent)
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────
-- DOWNTIME reason dimension + junction
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS downtime_reason (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_enterprise    integer     NOT NULL REFERENCES enterprises(id_enterprise),
  code             varchar     NOT NULL,
  label            varchar,                       -- flattened en-US convenience
  label_i18n       jsonb,                         -- full i18n map (no data loss)
  category         varchar,                       -- parent category code; NULL for category-level rows
  parent_id        bigint      REFERENCES downtime_reason(id),
  reason_level     smallint    NOT NULL DEFAULT 1,  -- 1=category, 2=subcategory
  planned_downtime boolean     NOT NULL DEFAULT false,
  change_over      boolean     NOT NULL DEFAULT false,
  idle             boolean     NOT NULL DEFAULT false,
  active           boolean     NOT NULL DEFAULT true,
  valid_from       timestamptz NOT NULL DEFAULT now(),
  valid_to         timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS downtime_reason_code_active_un
  ON downtime_reason (id_enterprise, code) WHERE active;

CREATE TABLE IF NOT EXISTS equipment_downtime_reason (
  id_equipment integer     NOT NULL REFERENCES equipments(id_equipment),
  id_reason    bigint      NOT NULL REFERENCES downtime_reason(id),
  active       boolean     NOT NULL DEFAULT true,
  valid_from   timestamptz NOT NULL DEFAULT now(),
  valid_to     timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz,
  PRIMARY KEY (id_equipment, id_reason)
);
CREATE INDEX IF NOT EXISTS equipment_downtime_reason_reason_idx
  ON equipment_downtime_reason (id_reason);

-- ─────────────────────────────────────────────────────────────────────────
-- SCRAP reason dimension + junction (mirror shape; empty on staging today)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS scrap_reason (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_enterprise    integer     NOT NULL REFERENCES enterprises(id_enterprise),
  code             varchar     NOT NULL,
  label            varchar,
  label_i18n       jsonb,
  category         varchar,
  parent_id        bigint      REFERENCES scrap_reason(id),
  reason_level     smallint    NOT NULL DEFAULT 1,
  active           boolean     NOT NULL DEFAULT true,
  valid_from       timestamptz NOT NULL DEFAULT now(),
  valid_to         timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS scrap_reason_code_active_un
  ON scrap_reason (id_enterprise, code) WHERE active;

CREATE TABLE IF NOT EXISTS equipment_scrap_reason (
  id_equipment integer     NOT NULL REFERENCES equipments(id_equipment),
  id_reason    bigint      NOT NULL REFERENCES scrap_reason(id),
  active       boolean     NOT NULL DEFAULT true,
  valid_from   timestamptz NOT NULL DEFAULT now(),
  valid_to     timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz,
  PRIMARY KEY (id_equipment, id_reason)
);
CREATE INDEX IF NOT EXISTS equipment_scrap_reason_reason_idx
  ON equipment_scrap_reason (id_reason);

-- ── updated_at triggers on the new dimension/junction tables
DROP TRIGGER IF EXISTS trg_set_updated_at ON downtime_reason;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON downtime_reason
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS trg_set_updated_at ON equipment_downtime_reason;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON equipment_downtime_reason
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS trg_set_updated_at ON scrap_reason;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON scrap_reason
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS trg_set_updated_at ON equipment_scrap_reason;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON equipment_scrap_reason
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ═══════════════════════════════════════════════════════════════════════════
-- BACKFILL (idempotent) — parse the existing jsonb arrays -> dimension + junction
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) DOWNTIME categories (reason_level=1), deduped per (enterprise, code).
INSERT INTO downtime_reason
  (id_enterprise, code, label, label_i18n, category, reason_level,
   planned_downtime, change_over, idle)
SELECT DISTINCT ON (e.id_enterprise, cat->>'code')
  e.id_enterprise,
  cat->>'code',
  cat->'description'->>'en-US',
  cat->'description',
  NULL::varchar,
  1,
  COALESCE((cat->>'planned_downtime')::boolean, false),
  COALESCE((cat->>'change_over')::boolean, false),
  COALESCE((cat->>'idle')::boolean, false)
FROM equipments e,
     jsonb_array_elements(e.downtime_reasons) elem,
     jsonb_array_elements(elem->'categories') cat
WHERE jsonb_typeof(e.downtime_reasons) = 'array'
  AND cat->>'code' IS NOT NULL
ORDER BY e.id_enterprise, cat->>'code'
ON CONFLICT (id_enterprise, code) WHERE active DO NOTHING;

-- 2) DOWNTIME subcategories (reason_level=2), deduped per (enterprise, code).
INSERT INTO downtime_reason
  (id_enterprise, code, label, label_i18n, category, reason_level,
   planned_downtime, change_over, idle)
SELECT DISTINCT ON (e.id_enterprise, sub->>'code')
  e.id_enterprise,
  sub->>'code',
  sub->'description'->>'en-US',
  sub->'description',
  cat->>'code',                      -- parent category code
  2,
  COALESCE((sub->>'planned_downtime')::boolean, false),
  COALESCE((sub->>'change_over')::boolean, false),
  COALESCE((sub->>'idle')::boolean, false)
FROM equipments e,
     jsonb_array_elements(e.downtime_reasons) elem,
     jsonb_array_elements(elem->'categories') cat,
     jsonb_array_elements(cat->'subcategories') sub
WHERE jsonb_typeof(e.downtime_reasons) = 'array'
  AND sub->>'code' IS NOT NULL
ORDER BY e.id_enterprise, sub->>'code'
ON CONFLICT (id_enterprise, code) WHERE active DO NOTHING;

-- 3) Wire subcategory.parent_id -> its category row (same enterprise + code).
UPDATE downtime_reason sub
SET parent_id = par.id
FROM downtime_reason par
WHERE sub.reason_level = 2
  AND sub.category IS NOT NULL
  AND sub.parent_id IS NULL
  AND par.reason_level = 1
  AND par.active
  AND par.id_enterprise = sub.id_enterprise
  AND par.code = sub.category;

-- 4) DOWNTIME junction: distinct (equipment, reason) across both levels.
INSERT INTO equipment_downtime_reason (id_equipment, id_reason)
SELECT DISTINCT e.id_equipment, r.id
FROM equipments e
CROSS JOIN LATERAL (
  SELECT cat->>'code' AS code
  FROM jsonb_array_elements(e.downtime_reasons) elem,
       jsonb_array_elements(elem->'categories') cat
  WHERE cat->>'code' IS NOT NULL
  UNION
  SELECT sub->>'code'
  FROM jsonb_array_elements(e.downtime_reasons) elem,
       jsonb_array_elements(elem->'categories') cat,
       jsonb_array_elements(cat->'subcategories') sub
  WHERE sub->>'code' IS NOT NULL
) codes
JOIN downtime_reason r
  ON r.id_enterprise = e.id_enterprise
 AND r.code = codes.code
 AND r.active
WHERE jsonb_typeof(e.downtime_reasons) = 'array'
ON CONFLICT (id_equipment, id_reason) DO NOTHING;

-- 5) SCRAP backfill — same shape; 0 rows on staging (scrap_reasons all empty).
INSERT INTO scrap_reason
  (id_enterprise, code, label, label_i18n, category, reason_level)
SELECT DISTINCT ON (e.id_enterprise, cat->>'code')
  e.id_enterprise, cat->>'code', cat->'description'->>'en-US',
  cat->'description', NULL::varchar, 1
FROM equipments e,
     jsonb_array_elements(e.scrap_reasons) elem,
     jsonb_array_elements(elem->'categories') cat
WHERE jsonb_typeof(e.scrap_reasons) = 'array'
  AND cat->>'code' IS NOT NULL
ORDER BY e.id_enterprise, cat->>'code'
ON CONFLICT (id_enterprise, code) WHERE active DO NOTHING;

COMMIT;

-- ── verification (read-only) — expected on staging 2026-07-23:
--   downtime_reason      : 54 rows (18 codes x 3 enterprises)
--   equipment_downtime_reason : 1188 rows (66 equip x 18 codes)
--   scrap_reason / equipment_scrap_reason : 0 rows
-- SELECT count(*) FROM downtime_reason;
-- SELECT count(*) FROM equipment_downtime_reason;
-- SELECT count(*) FROM scrap_reason;
-- SELECT count(*) FROM equipment_scrap_reason;
