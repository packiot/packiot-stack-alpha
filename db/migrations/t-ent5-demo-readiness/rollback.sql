-- rollback t-ent5-demo-readiness: restore speeds, targets and the test orders from the backup.
BEGIN;
UPDATE core.equipments e SET production_speed = (b.row->>'production_speed')::double precision
  FROM ops._bkp_ent5_demo_20260924 b
 WHERE b.kind = 'equipment_speed' AND e.id_equipment = (b.row->>'id_equipment')::int;
UPDATE config.production_targets t SET vl_hour = r.vl_hour, vl_shift = r.vl_shift, vl_day = r.vl_day,
       vl_week = r.vl_week, vl_month = r.vl_month
  FROM ops._bkp_ent5_demo_20260924 b, jsonb_populate_record(NULL::config.production_targets, b.row) r
 WHERE b.kind = 'production_target' AND t.id_equipment = r.id_equipment;
INSERT INTO core.production_orders
  SELECT (jsonb_populate_record(NULL::core.production_orders, row)).* FROM ops._bkp_ent5_demo_20260924
   WHERE kind = 'production_order' ON CONFLICT DO NOTHING;
INSERT INTO gold.production_orders_runtime
  SELECT (jsonb_populate_record(NULL::gold.production_orders_runtime, row)).* FROM ops._bkp_ent5_demo_20260924
   WHERE kind = 'po_runtime' ON CONFLICT DO NOTHING;
-- the target-hour ×60 fix is NOT rolled back (it is a units bug fix, independent of the demo).
COMMIT;
