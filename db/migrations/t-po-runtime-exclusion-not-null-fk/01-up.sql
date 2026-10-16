-- t-po-runtime-exclusion-not-null-fk — make the PO-runtime no-overlap guarantee total: NOT NULL operands + FK.
--
-- WHY: gold.production_orders_runtime carries
--     production_orders_runtime_id_equipment_runtime_timerange_excl
--       EXCLUDE USING gist (id_equipment WITH =, runtime_timerange WITH &&)
-- — "one equipment never runs two PO windows at the same instant", the invariant the PO engine, the replicator
-- (`&&` guard in sqlOpenWindow) and the downtime/OEE attribution all rely on. But BOTH operands are nullable, and an
-- exclusion constraint only compares rows whose operator evaluates to TRUE: `NULL = 10` and `NULL && '[a,b)'` are
-- NULL, not TRUE, so a row with a NULL id_equipment or a NULL runtime_timerange is invisible to the constraint and can
-- overlap anything. id_equipment also has no FK, so a window can point at an equipment that does not exist.
-- Today: null_frac 0.000 for both columns (schema review 2026-10-06, 57,080 rows) → the fix costs nothing now and
-- closes the hole before a writer regression can use it.
--
-- WRITERS (all supply both, verified 2026-10-06):
--   stream-engine  services/stream-engine/internal/pocontrol/pocontrol.go:267-269 (VALUES ($1, tstzrange($2, NULL,'[)'), true, $3) with
--                  info.IDEquipment); :255 / :306 UPDATEs rebuild the range with tstzrange(...) — never NULL
--   analytics-sync services/analytics-sync/internal/replicate/handlers.go:253 sqlOpenWindow, reconcile.go:123 sqlReconcileBackfillWindow,
--                  internal/replay/handlers/production_orders.go:210 — id_equipment = po.id_equipment (core.production_orders.id_equipment
--                  is NOT NULL + FK), range = tstzrange(...) (a range constructor never returns NULL, even for NULL bounds)
--   mirror-worker  services/mirror-worker-go/internal/db/staging.go:426,559,770 — UPDATE only, tstzrange(lower, GREATEST(...))
--   edge-api       edge-api/src/data/DAO/production-orders/production-orders-dao.ts:68,254 ($1 = input.idEquipment, @IsNotEmpty in
--                  start-production-order.dto.ts:23 / create-and-start.dto.ts:19; range '[ts,)'::tstzrange), :530 (tstzrange($10,NULL,'[)'), $4)
--   sandbox        t-sandbox-reflection/01-up.sql:277 copies CPACK rows (already non-NULL) with id_equipment remapped to the twin's ids
--
-- LOCKING (why it is split into three short transactions instead of one ALTER):
--   * SET NOT NULL normally scans the whole table under ACCESS EXCLUSIVE (blocks every reader and writer for the scan).
--     Since PG 12 it SKIPS the scan when a VALIDATED `CHECK (col IS NOT NULL)` already proves it. So: add the CHECK
--     NOT VALID (catalog-only, brief ACCESS EXCLUSIVE), VALIDATE it (scan under SHARE UPDATE EXCLUSIVE — reads and
--     writes continue), then SET NOT NULL (brief ACCESS EXCLUSIVE, no scan) and drop the helper CHECK.
--   * The FK: ADD ... NOT VALID takes SHARE ROW EXCLUSIVE on both tables for a catalog-only change (new rows are checked
--     from that instant); VALIDATE CONSTRAINT then scans under SHARE UPDATE EXCLUSIVE on the runtime table and ROW SHARE
--     on core.equipments — neither blocks the stream-engine rollups' long ACCESS SHARE reads of core.equipments.
--   * The validations MUST commit in their own transaction: locks are held to COMMIT, so NOT VALID + VALIDATE + SET NOT
--     NULL in one transaction would hold the ACCESS EXCLUSIVE across the scans and gain nothing.
--   lock_timeout 3s on every step: if a step cannot get its lock it fails fast and the file is simply re-run
--   (every step is idempotent).
-- ON DELETE NO ACTION (the default; same family as production_orders_id_equipment_foreign RESTRICT): equipments are never
-- hard-deleted by the product (edge-api equipments-dao.ts delete() = soft delete, active=false), so a DELETE of an
-- equipment that still has PO windows is an ops mistake that should fail, not cascade history away or orphan it.

\set ON_ERROR_STOP 1

-- ---- step 1: guards + NOT VALID constraints (catalog-only) ----
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $$ DECLARE n_eq bigint; n_rng bigint; n_orphan bigint; BEGIN
  SELECT count(*) FILTER (WHERE id_equipment IS NULL),
         count(*) FILTER (WHERE runtime_timerange IS NULL),
         count(*) FILTER (WHERE id_equipment IS NOT NULL
                            AND NOT EXISTS (SELECT 1 FROM core.equipments e WHERE e.id_equipment = r.id_equipment))
    INTO n_eq, n_rng, n_orphan
    FROM gold.production_orders_runtime r;
  IF n_eq + n_rng + n_orphan > 0 THEN
    RAISE EXCEPTION 't-po-runtime-exclusion-not-null-fk: refusing — % row(s) with NULL id_equipment, % with NULL runtime_timerange, % with an id_equipment not in core.equipments. Repair (or delete) them first; see db/migrations/_probes/schema-p1/a-guard-counts.sql',
      n_eq, n_rng, n_orphan;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'gold.production_orders_runtime'::regclass AND attname = 'id_equipment')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'gold.production_orders_runtime'::regclass AND conname = 'production_orders_runtime_id_equipment_nn') THEN
    ALTER TABLE gold.production_orders_runtime ADD CONSTRAINT production_orders_runtime_id_equipment_nn CHECK (id_equipment IS NOT NULL) NOT VALID;
  END IF;
  IF NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'gold.production_orders_runtime'::regclass AND attname = 'runtime_timerange')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'gold.production_orders_runtime'::regclass AND conname = 'production_orders_runtime_timerange_nn') THEN
    ALTER TABLE gold.production_orders_runtime ADD CONSTRAINT production_orders_runtime_timerange_nn CHECK (runtime_timerange IS NOT NULL) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'gold.production_orders_runtime'::regclass AND conname = 'production_orders_runtime_id_equipment_fkey') THEN
    ALTER TABLE gold.production_orders_runtime
      ADD CONSTRAINT production_orders_runtime_id_equipment_fkey FOREIGN KEY (id_equipment)
      REFERENCES core.equipments (id_equipment) ON UPDATE NO ACTION ON DELETE NO ACTION NOT VALID;
  END IF;
END $$;
COMMIT;

-- ---- step 2: validate (full scan under SHARE UPDATE EXCLUSIVE; DML keeps flowing) ----
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $$ DECLARE c text; BEGIN
  FOR c IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'gold.production_orders_runtime'::regclass AND NOT convalidated
              AND conname IN ('production_orders_runtime_id_equipment_nn', 'production_orders_runtime_timerange_nn',
                              'production_orders_runtime_id_equipment_fkey') LOOP
    EXECUTE format('ALTER TABLE gold.production_orders_runtime VALIDATE CONSTRAINT %I', c);
  END LOOP;
END $$;
COMMIT;

-- ---- step 3: SET NOT NULL (no scan: the validated CHECKs prove it) and drop the helper CHECKs ----
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $$ BEGIN
  IF NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'gold.production_orders_runtime'::regclass AND attname = 'id_equipment') THEN
    ALTER TABLE gold.production_orders_runtime ALTER COLUMN id_equipment SET NOT NULL;
  END IF;
  IF NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'gold.production_orders_runtime'::regclass AND attname = 'runtime_timerange') THEN
    ALTER TABLE gold.production_orders_runtime ALTER COLUMN runtime_timerange SET NOT NULL;
  END IF;
END $$;
ALTER TABLE gold.production_orders_runtime DROP CONSTRAINT IF EXISTS production_orders_runtime_id_equipment_nn;
ALTER TABLE gold.production_orders_runtime DROP CONSTRAINT IF EXISTS production_orders_runtime_timerange_nn;
COMMENT ON CONSTRAINT production_orders_runtime_id_equipment_fkey ON gold.production_orders_runtime IS
  'Every PO window belongs to an existing equipment (t-po-runtime-exclusion-not-null-fk). Equipments are soft-deleted; a hard delete with windows fails.';
COMMIT;
