-- 0039-dimension-scd2-history.sql — R6 follow-up: the SCD-2 *_history tables +
-- prior-version-capture trigger for the core dimensions.
-- ADR: 0039 (entity-lifecycle) · Tier 2 (SCD-2 history for genealogy-bearing
-- dimensions) · builds directly on 0039-dimension-scd2-temporal.sql (R6), which
-- added valid_from/valid_to/created_at/updated_at + a set_updated_at() trigger
-- to equipments/sites/areas/enterprises but DEFERRED the *_history machinery.
--
-- WHY (ADR-0039 §5 Tier 2, §3 "SCD-versioned history for DIMENSIONS"):
--   R6 laid the temporal COLUMNS but the live dimension row still only holds the
--   CURRENT version. valid_from tells you when the current config took effect,
--   but the moment `ideal_speed` / `id_area` / `nm_equipment` is edited, the
--   PRIOR value is gone (SCD-1 overwrite). So the platform still cannot answer
--   ADR-0038 pillar P7's genealogy question — "what was this equipment's config
--   when that historical OEE was computed?" — because there is no row that
--   remembers the superseded version.
--
--   This migration adds the missing half: one *_history row per UPDATE, holding
--   the SUPERSEDED version with its validity interval CLOSED (valid_to = the
--   moment of change). A fact at time T then joins the history version whose
--   [valid_from, valid_to) interval contains T. Kimball SCD Type-2, exactly.
--
-- SCOPE — the four dimensions R6 gave temporal columns: equipments, sites,
--   areas, enterprises. (ADR-0039 Tier-2 also names packml_register /
--   production_orders / shifts, but those have no temporal columns yet — they
--   land when R6 is extended to them; see ADR-0039 §5 Tier 2 + §6 phase T2.)
--
-- MECHANISM — schema-robust prior-version capture:
--   equipments has 51 columns, so the trigger does NOT enumerate columns.
--   Instead it snapshots OLD via to_jsonb(OLD), overrides valid_to (close the
--   interval), history_id and changed_at, and rebuilds the row with
--   jsonb_populate_record(NULL::<t>_history, ...). This survives ordinary column
--   additions to the dimension without a trigger rewrite (a new column simply
--   flows through once the *_history table is ALTER-ed to carry it too). This is
--   the same to_jsonb/populate-record pattern the well-known Postgres
--   audit-trigger frameworks use for column-agnostic row capture.
--
--   The BEFORE-UPDATE trigger ALSO rolls the LIVE row's valid_from -> now(), so
--   the new current version's validity STARTS where the superseded version's
--   ended: the history intervals + the live row tile the timeline with no gap
--   and no overlap. It coexists with R6's trg_set_updated_at (both BEFORE UPDATE;
--   they touch disjoint NEW fields — updated_at vs valid_from).
--
-- HISTORY TABLE SHAPE — `LIKE <dimension>` (columns + NOT NULL only; NO indexes,
--   NO PK/uniques copied, so many versions per natural key are allowed) plus:
--     history_id  bigint  — surrogate PK, own sequence
--     changed_at  timestamptz — audit stamp of the change (= closed valid_to)
--   valid_from / valid_to come in via LIKE (they are dimension columns since R6).
--   One lightweight lookup index per table: (natural_key, valid_from) — the
--   genealogy "version valid at T" access path.
--
-- SAFETY: additive DDL only; fully reversible (DOWN block at the foot DROPs the
--   history tables, sequences, triggers and the shared function). Idempotent
--   (CREATE ... IF NOT EXISTS everywhere; CREATE OR REPLACE FUNCTION; DROP
--   TRIGGER IF EXISTS before CREATE). Staging first; prod applies under the
--   standing prod gate (prod DB is SELECT-only for us).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── shared prior-version capture function (generic over the triggering table) ──
-- On UPDATE: insert OLD as a closed SCD-2 version into <table>_history, then roll
-- the live row's valid_from forward so the surviving row is the new open version.
CREATE OR REPLACE FUNCTION log_dimension_history() RETURNS trigger AS $$
DECLARE
  hist_tbl text := TG_TABLE_NAME || '_history';
  hist_seq text := TG_TABLE_NAME || '_history_history_id_seq';
  audit_cols text[] := ARRAY['valid_from','valid_to','created_at','updated_at'];
BEGIN
  -- Change-guard: only version on a SUBSTANTIVE change. Strip the temporal/audit
  -- columns (R6's updated_at bump, our own valid_from roll) before comparing, so a
  -- no-op UPDATE or a pure touch does not spawn a spurious history version.
  IF (to_jsonb(OLD) - audit_cols) IS NOT DISTINCT FROM (to_jsonb(NEW) - audit_cols) THEN
    RETURN NEW;
  END IF;

  EXECUTE format(
    'INSERT INTO %I SELECT (jsonb_populate_record(NULL::%I,'
    ' $1 || jsonb_build_object('
    '   ''history_id'', nextval(%L),'   -- surrogate PK for this version row
    '   ''valid_to'',   $2,'            -- close the superseded interval at change time
    '   ''changed_at'', $2))).*',       -- audit stamp
    hist_tbl, hist_tbl, hist_seq
  ) USING to_jsonb(OLD), now();

  NEW.valid_from := now();  -- the surviving live row is the NEW version: it starts now
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ── per-dimension: sequence + history table + lookup index + trigger ──────────
-- Applied uniformly to the four dimensions R6 gave temporal columns. The natural
-- key differs per table (id_equipment / id_site / id_area / id_enterprise) and is
-- used only for the lookup index.
DO $do$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('equipments',  'id_equipment'),
      ('sites',       'id_site'),
      ('areas',       'id_area'),
      ('enterprises', 'id_enterprise')
    ) AS t(dim, natural_key)
  LOOP
    -- surrogate-key sequence
    EXECUTE format('CREATE SEQUENCE IF NOT EXISTS %I', r.dim || '_history_history_id_seq');

    -- history table: LIKE the dimension (cols + NOT NULL, no PK/index/default) +
    -- surrogate history_id + changed_at
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS %I ('
      '  history_id bigint DEFAULT nextval(%L) PRIMARY KEY,'
      '  changed_at timestamptz NOT NULL DEFAULT now(),'
      '  LIKE %I)',
      r.dim || '_history', r.dim || '_history_history_id_seq', r.dim
    );

    -- genealogy "version valid at T" lookup path
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I ON %I (%I, valid_from)',
      r.dim || '_history_key_valid_from_idx', r.dim || '_history', r.natural_key
    );

    -- BEFORE-UPDATE capture trigger (coexists with R6's trg_set_updated_at)
    EXECUTE format('DROP TRIGGER IF EXISTS trg_scd2_history ON %I', r.dim);
    EXECUTE format(
      'CREATE TRIGGER trg_scd2_history BEFORE UPDATE ON %I'
      ' FOR EACH ROW EXECUTE FUNCTION log_dimension_history()',
      r.dim
    );
  END LOOP;
END
$do$;

COMMIT;

-- ── verification (read-only) ────────────────────────────────────────────────
-- Expected: 4 history tables present; each carries history_id + changed_at + the
-- dimension's temporal cols; a test UPDATE on any dimension produces exactly one
-- history row holding the OLD values with valid_to = changed_at, while the live
-- row's valid_from advances. (See PR body for the executed, self-rolled-back proof.)
--
-- SELECT tablename FROM pg_tables WHERE tablename LIKE '%\_history' ESCAPE '\'
--   AND tablename IN ('equipments_history','sites_history','areas_history','enterprises_history')
-- ORDER BY 1;
--
-- SELECT event_object_table AS tbl, trigger_name FROM information_schema.triggers
-- WHERE trigger_name = 'trg_scd2_history' ORDER BY 1;

-- ═══════════════════════════════════════════════════════════════════════════
-- DOWN (reverse) — reversible; run only to roll this migration back.
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_scd2_history ON equipments;
-- DROP TRIGGER IF EXISTS trg_scd2_history ON sites;
-- DROP TRIGGER IF EXISTS trg_scd2_history ON areas;
-- DROP TRIGGER IF EXISTS trg_scd2_history ON enterprises;
-- DROP FUNCTION IF EXISTS log_dimension_history();
-- DROP TABLE IF EXISTS equipments_history, sites_history, areas_history, enterprises_history;
-- -- sequences are dropped with their owning table's DEFAULT? No — they are
-- -- standalone; drop explicitly:
-- DROP SEQUENCE IF EXISTS equipments_history_history_id_seq, sites_history_history_id_seq,
--   areas_history_history_id_seq, enterprises_history_history_id_seq;
-- COMMIT;
