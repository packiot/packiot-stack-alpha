-- verify for t-equipments-self-fks. Every line prints label|value; the expected value is in the label.
-- The negative tests write inside a transaction that is rolled back.
\set ON_ERROR_STOP 1

SELECT 'V1 validated self-FKs on lead/gross/scrap/net/parent (NO ACTION): 5|5|5',
       count(*), count(*) FILTER (WHERE convalidated), count(*) FILTER (WHERE confdeltype = 'a' AND confupdtype = 'a')
  FROM pg_constraint c
 WHERE c.conrelid = 'core.equipments'::regclass AND c.contype = 'f' AND c.confrelid = c.conrelid
   AND (SELECT attname FROM pg_attribute WHERE attrelid = c.conrelid AND attnum = c.conkey[1])
       IN ('lead_machine', 'gross_machine', 'scrap_machine', 'net_machine', 'id_parentequipment');
SELECT 'V2 no-op self-FK id_equipment → id_equipment present: 0', count(*)
  FROM pg_constraint c WHERE c.conrelid = 'core.equipments'::regclass AND c.contype = 'f'
   AND c.confrelid = c.conrelid AND c.conkey = c.confkey;
SELECT 'V3 type drift kept as follow-up (lead_machine|gross_machine|scrap_machine|id_parentequipment): integer|bigint|bigint|integer',
       format_type(max(atttypid) FILTER (WHERE attname = 'lead_machine'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'gross_machine'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'scrap_machine'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'id_parentequipment'), NULL)
  FROM pg_attribute WHERE attrelid = 'core.equipments'::regclass;

BEGIN;
DO $$ DECLARE c text; bad bigint; BEGIN
  bad := (SELECT max(id_equipment) + 1000000 FROM core.equipments);
  FOREACH c IN ARRAY ARRAY['lead_machine', 'gross_machine', 'scrap_machine', 'id_parentequipment'] LOOP
    BEGIN
      EXECUTE format('UPDATE core.equipments SET %I = $1 WHERE id_equipment = (SELECT min(id_equipment) FROM core.equipments)', c) USING bad;
      RAISE NOTICE 'V4 FAIL: dangling % accepted', c;
    EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'V4 dangling % rejected: ok', c;
    END;
  END LOOP;
END $$;
-- hard-deleting a machine that some row still references must fail (NO ACTION)
DO $$ BEGIN
  DELETE FROM core.equipments
   WHERE id_equipment = (SELECT min(lead_machine) FROM core.equipments WHERE lead_machine IS NOT NULL AND lead_machine <> id_equipment);
  RAISE NOTICE 'V5 FAIL (or no line has a lead_machine): referenced machine deleted';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'V5 delete of a referenced lead machine rejected: ok';
END $$;
ROLLBACK;
