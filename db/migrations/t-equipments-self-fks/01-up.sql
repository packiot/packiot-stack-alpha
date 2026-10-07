-- t-equipments-self-fks — FKs for core.equipments' self-references; drop the no-op self-FK.
--
-- WHY: four columns of core.equipments point at another equipment and drive line attribution, yet only net_machine
-- has an FK (equipments_net_machine_fkey):
--   lead_machine       the machine that REPRESENTS a line (downtime + counters; stream-engine rollup/line_lead.go)
--   gross_machine      split-instrumentation infeed meter (ADR-0045; edge-api equipments-dao.ts updateLineMeters)
--   scrap_machine      split-instrumentation scrap meter
--   id_parentequipment hierarchy (line → sector → machine; edge-api move() walks it, read-api refdata main.go:163 joins it)
-- A typo'd or stale id there silently attributes a line to nothing (or to a machine that no longer exists) — nothing
-- rejects it. Repo ≠ live: db/init/13…:41 / 14…:41 declare REFERENCES for gross/scrap, but live never got them because
-- db/cutover/f3-schema-parity.sql:223-224 added the columns first without REFERENCES, turning the later
-- `ADD COLUMN IF NOT EXISTS … REFERENCES` into a no-op. Meanwhile live carries
-- equipments_id_equipment_foreign = FOREIGN KEY (id_equipment) REFERENCES equipments(id_equipment): a row referencing
-- ITSELF, always satisfied, enforcing nothing — but it still costs an RI trigger pair on every insert/update/delete
-- and misleads anyone reading \d.
--
-- ON DELETE / ON UPDATE NO ACTION (decided from how equipment is removed):
--   * the product never hard-deletes equipment: edge-api equipments-dao.ts delete() (:487-537) is a soft delete
--     (active = false + fence packml_register in one CTE), and create() (:180-209) REACTIVATES a soft-deleted row
--     under the SAME id_equipment — so references stay valid across delete/re-onboard round-trips;
--   * a hard DELETE of a machine that a line still names as lead/gross/scrap or a child still names as parent is an
--     ops mistake → it must FAIL (not SET NULL: silently nulling lead_machine re-attributes a line's downtime and
--     counters with no trace; not CASCADE: deleting a machine must never delete its line);
--   * a whole-tenant purge in ONE statement (scripts/provision-sandbox-tenant.sh:117
--     `DELETE FROM equipments WHERE id_enterprise = …`) still succeeds: the self-reference check runs after the
--     statement, when line and machines are gone together (verified locally).
--   * NO ACTION rather than RESTRICT: identical behaviour while non-deferrable (both fail the statement), but NO ACTION
--     can later be made DEFERRABLE for multi-statement re-wiring; and it is what equipments_net_machine_fkey uses.
-- Plain (single-column) FKs, not (col, id_enterprise) composites: the sandbox reflect (t-sandbox-reflection:136-140)
-- copies gross/scrap/net unmapped and t-sandbox-attribution-sync remaps them a step later, so a tenant-composite FK
-- would break the twin heal. Cross-tenant references are counted in _probes/schema-p1/a-guard-counts.sql instead.
--
-- TYPES (documented follow-up, NOT done here): lead_machine / id_parentequipment are int4 like the PK, gross_machine /
-- scrap_machine / net_machine are int8. An int8 → int4 FK is legal (btree integer_ops is cross-type; net_machine already
-- does it). Aligning the types is not "trivial and safe": int8 → int4 is not binary-coercible, so ALTER COLUMN TYPE
-- REWRITES core.equipments under ACCESS EXCLUSIVE (the stream-engine rollups hold ACCESS SHARE on this table for 60 s+
-- back-to-back, so the rewrite's lock queues and stalls every reader behind it — see tRD-core-gold-column-hardening),
-- it rebuilds the FKs/indexes on the column, and it is refused outright while a view projects the column
-- (bi.equipments projects lead_machine — analytics-clean-schema/06_p2_bi_next_security_invoker_views.sql:16).
-- Do it in a maintenance window together with the dependent views, or leave it: values are equipment ids (< 2^31).
--
-- LOCKING: ADD FOREIGN KEY … NOT VALID takes SHARE ROW EXCLUSIVE (does NOT conflict with the rollups' ACCESS SHARE;
-- briefly blocks csadmin writes) and is catalog-only; VALIDATE takes SHARE UPDATE EXCLUSIVE + ROW SHARE (blocks
-- nothing) and scans 283 rows. Committed separately so no strong lock spans the validation. DROP CONSTRAINT on the
-- no-op FK needs ACCESS EXCLUSIVE → its own last transaction with lock_timeout 3s: if the rollups hold the table it
-- fails fast (the new FKs are already in place); just re-run the file (every step is idempotent).

\set ON_ERROR_STOP 1

-- ---- step 1: orphan guard + NOT VALID FKs ----
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $$ DECLARE r record; msg text := ''; BEGIN
  FOR r IN
    SELECT c.col,
           count(*) FILTER (WHERE c.v IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.equipments t WHERE t.id_equipment = c.v)) AS orphans,
           count(*) FILTER (WHERE c.v = 0) AS zeros
      FROM core.equipments e
      CROSS JOIN LATERAL (VALUES ('lead_machine', e.lead_machine::bigint), ('gross_machine', e.gross_machine),
                                 ('scrap_machine', e.scrap_machine), ('id_parentequipment', e.id_parentequipment::bigint)) AS c(col, v)
     GROUP BY c.col ORDER BY c.col
  LOOP
    IF r.orphans > 0 THEN
      msg := msg || format(' %s=%s (of which value 0: %s);', r.col, r.orphans, r.zeros);
    END IF;
  END LOOP;
  IF msg <> '' THEN
    RAISE EXCEPTION 't-equipments-self-fks: refusing — values that match no core.equipments.id_equipment:%  Fix (NULL the unset ones, correct the stale ones) first; see db/migrations/_probes/schema-p1/a-guard-counts.sql', msg;
  END IF;
END $$;

DO $$ DECLARE c record; BEGIN
  FOR c IN SELECT * FROM (VALUES ('equipments_lead_machine_fkey', 'lead_machine'),
                                 ('equipments_gross_machine_fkey', 'gross_machine'),
                                 ('equipments_scrap_machine_fkey', 'scrap_machine'),
                                 ('equipments_id_parentequipment_fkey', 'id_parentequipment')) v(conname, col)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'core.equipments'::regclass AND conname = c.conname) THEN
      EXECUTE format('ALTER TABLE core.equipments ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES core.equipments (id_equipment)'
                     ' ON UPDATE NO ACTION ON DELETE NO ACTION NOT VALID', c.conname, c.col);
    END IF;
  END LOOP;
END $$;
COMMIT;

-- ---- step 2: validate (SHARE UPDATE EXCLUSIVE; reads and writes continue) ----
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $$ DECLARE c text; BEGIN
  FOR c IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'core.equipments'::regclass AND NOT convalidated
              AND conname IN ('equipments_lead_machine_fkey', 'equipments_gross_machine_fkey',
                              'equipments_scrap_machine_fkey', 'equipments_id_parentequipment_fkey') LOOP
    EXECUTE format('ALTER TABLE core.equipments VALIDATE CONSTRAINT %I', c);
  END LOOP;
END $$;
COMMENT ON CONSTRAINT equipments_lead_machine_fkey ON core.equipments IS 'line → its representative machine (t-equipments-self-fks). NO ACTION: equipment is soft-deleted; a hard delete of a referenced machine fails.';
COMMENT ON CONSTRAINT equipments_gross_machine_fkey ON core.equipments IS 'line → infeed meter machine, ADR-0045 (t-equipments-self-fks).';
COMMENT ON CONSTRAINT equipments_scrap_machine_fkey ON core.equipments IS 'line → scrap meter machine, ADR-0045 (t-equipments-self-fks).';
COMMENT ON CONSTRAINT equipments_id_parentequipment_fkey ON core.equipments IS 'hierarchy child → parent equipment (t-equipments-self-fks).';
COMMIT;

-- ---- step 3: drop the no-op self-FK (ACCESS EXCLUSIVE, brief; re-run on lock_timeout) ----
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $$ BEGIN
  -- only drop it if it really is the no-op shape id_equipment → id_equipment on the same table
  IF EXISTS (SELECT 1 FROM pg_constraint c
              WHERE c.conrelid = 'core.equipments'::regclass AND c.conname = 'equipments_id_equipment_foreign'
                AND c.contype = 'f' AND c.confrelid = c.conrelid AND c.conkey = c.confkey) THEN
    ALTER TABLE core.equipments DROP CONSTRAINT equipments_id_equipment_foreign;
  END IF;
END $$;
COMMIT;
