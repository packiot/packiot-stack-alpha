-- verify for t-po-runtime-exclusion-not-null-fk. Every line prints label|value; the expected value is in the label.
-- The negative tests write inside a transaction that is rolled back.
\set ON_ERROR_STOP 1

SELECT 'V1 id_equipment NOT NULL|runtime_timerange NOT NULL: t|t',
       bool_or(attnotnull) FILTER (WHERE attname = 'id_equipment'),
       bool_or(attnotnull) FILTER (WHERE attname = 'runtime_timerange')
  FROM pg_attribute WHERE attrelid = 'gold.production_orders_runtime'::regclass AND attname IN ('id_equipment', 'runtime_timerange');
SELECT 'V2 FK id_equipment → core.equipments present and validated: 1|t',
       count(*), bool_and(convalidated)
  FROM pg_constraint WHERE conrelid = 'gold.production_orders_runtime'::regclass AND contype = 'f'
   AND confrelid = 'core.equipments'::regclass AND conname = 'production_orders_runtime_id_equipment_fkey';
SELECT 'V3 helper CHECKs left behind: 0', count(*) FROM pg_constraint
 WHERE conrelid = 'gold.production_orders_runtime'::regclass
   AND conname IN ('production_orders_runtime_id_equipment_nn', 'production_orders_runtime_timerange_nn');
SELECT 'V4 exclusion constraint still present: 1', count(*) FROM pg_constraint
 WHERE conrelid = 'gold.production_orders_runtime'::regclass AND contype = 'x'
   AND conname = 'production_orders_runtime_id_equipment_runtime_timerange_excl';

BEGIN;
DO $$ BEGIN
  INSERT INTO gold.production_orders_runtime (id_production_order, id_equipment, runtime_timerange, recalc_needed)
  SELECT id_production_order, NULL, tstzrange('2999-01-01', '2999-01-02'), false FROM core.production_orders LIMIT 1;
  RAISE NOTICE 'V5 FAIL: NULL id_equipment accepted';
EXCEPTION WHEN not_null_violation THEN RAISE NOTICE 'V5 NULL id_equipment rejected: ok';
END $$;
DO $$ BEGIN
  INSERT INTO gold.production_orders_runtime (id_production_order, id_equipment, runtime_timerange, recalc_needed)
  SELECT po.id_production_order, po.id_equipment, NULL, false FROM core.production_orders po LIMIT 1;
  RAISE NOTICE 'V6 FAIL: NULL runtime_timerange accepted';
EXCEPTION WHEN not_null_violation THEN RAISE NOTICE 'V6 NULL runtime_timerange rejected: ok';
END $$;
DO $$ BEGIN
  INSERT INTO gold.production_orders_runtime (id_production_order, id_equipment, runtime_timerange, recalc_needed)
  SELECT id_production_order, (SELECT max(id_equipment) + 1000000 FROM core.equipments), tstzrange('2999-01-01', '2999-01-02'), false
    FROM core.production_orders LIMIT 1;
  RAISE NOTICE 'V7 FAIL: orphan id_equipment accepted';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'V7 orphan id_equipment rejected: ok';
END $$;
ROLLBACK;
