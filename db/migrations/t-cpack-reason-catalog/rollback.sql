-- t-cpack-reason-catalog / rollback.sql — restore CPACK's (ent 3) three reason structures to the
-- EXACT rows 01-up.sql snapshotted (ops._bkp_cpack_reason_catalog_*): same ids, same timestamps,
-- same equipments.downtime_reasons + updated_at. Touches ent 3 only; drops the snapshot at the end.
BEGIN;
SET LOCAL statement_timeout = '5min';
SET LOCAL lock_timeout = '15s';

DO $g$ BEGIN
  IF to_regclass('ops._bkp_cpack_reason_catalog_eq') IS NULL
     OR to_regclass('ops._bkp_cpack_reason_catalog_dr') IS NULL
     OR to_regclass('ops._bkp_cpack_reason_catalog_edr') IS NULL THEN
    RAISE EXCEPTION 't-cpack-reason-catalog rollback: snapshot tables missing — nothing to restore from';
  END IF;
  IF EXISTS (SELECT 1 FROM core.downtime_reason d JOIN ops._bkp_cpack_reason_catalog_dr b USING (id)
              WHERE d.id_enterprise <> 3) THEN
    RAISE EXCEPTION 'a snapshotted reason id is now used by another enterprise — refusing';
  END IF;
END $g$;

-- 1. catalog: drop the ported rows, re-insert the snapshot verbatim (ids included)
DELETE FROM core.equipment_downtime_reason j USING core.equipments e
 WHERE j.id_equipment = e.id_equipment AND e.id_enterprise = 3;
DELETE FROM core.downtime_reason WHERE id_enterprise = 3;
INSERT INTO core.downtime_reason OVERRIDING SYSTEM VALUE
SELECT * FROM ops._bkp_cpack_reason_catalog_dr;
INSERT INTO core.equipment_downtime_reason
SELECT * FROM ops._bkp_cpack_reason_catalog_edr;

-- 2. per-equipment trees; trg_set_updated_at is suspended for THIS statement only so
--    updated_at comes back exactly as snapshotted (ALTER … DISABLE TRIGGER is transactional).
ALTER TABLE core.equipments DISABLE TRIGGER trg_set_updated_at;
UPDATE core.equipments e
   SET downtime_reasons = b.downtime_reasons, updated_at = b.updated_at
  FROM ops._bkp_cpack_reason_catalog_eq b
 WHERE e.id_equipment = b.id_equipment AND e.id_enterprise = 3;
ALTER TABLE core.equipments ENABLE TRIGGER trg_set_updated_at;

-- 3. prove it, then drop the snapshot
DO $g$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM (
    (SELECT * FROM core.downtime_reason WHERE id_enterprise = 3 EXCEPT SELECT * FROM ops._bkp_cpack_reason_catalog_dr)
    UNION ALL
    (SELECT * FROM ops._bkp_cpack_reason_catalog_dr EXCEPT SELECT * FROM core.downtime_reason WHERE id_enterprise = 3)) x;
  IF n > 0 THEN RAISE EXCEPTION 'downtime_reason restore differs in % rows', n; END IF;
  SELECT count(*) INTO n FROM (
    (SELECT j.* FROM core.equipment_downtime_reason j JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise = 3
     EXCEPT SELECT * FROM ops._bkp_cpack_reason_catalog_edr)
    UNION ALL
    (SELECT * FROM ops._bkp_cpack_reason_catalog_edr
     EXCEPT SELECT j.* FROM core.equipment_downtime_reason j JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise = 3)) x;
  IF n > 0 THEN RAISE EXCEPTION 'equipment_downtime_reason restore differs in % rows', n; END IF;
  SELECT count(*) INTO n FROM core.equipments e JOIN ops._bkp_cpack_reason_catalog_eq b USING (id_equipment)
   WHERE e.downtime_reasons IS DISTINCT FROM b.downtime_reasons OR e.updated_at IS DISTINCT FROM b.updated_at;
  IF n > 0 THEN RAISE EXCEPTION 'equipments restore differs in % rows', n; END IF;
END $g$;

DROP TABLE ops._bkp_cpack_reason_catalog_eq, ops._bkp_cpack_reason_catalog_dr, ops._bkp_cpack_reason_catalog_edr;
COMMIT;
