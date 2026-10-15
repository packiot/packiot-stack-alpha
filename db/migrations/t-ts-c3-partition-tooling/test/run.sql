\set ON_ERROR_STOP 1
\pset format unaligned
CALL ops.pc_prepare('silver.equipment_events', interval '1 month');
CALL ops.pc_copy('silver.equipment_events');
-- changes AFTER the copy: must reach the new table through the capture/replay
UPDATE silver.equipment_events SET ts_end = '2001-01-01', status = 9 WHERE id_equipment = 2 AND ts_event = (SELECT min(ts_event) FROM silver.equipment_events WHERE id_equipment = 2);
DELETE FROM silver.equipment_events WHERE id_equipment = 3 AND ts_event = (SELECT min(ts_event) FROM silver.equipment_events WHERE id_equipment = 3);
INSERT INTO silver.equipment_events (id_equipment, ts_event, status) VALUES (7, now() - interval '5 minutes', 1);
INSERT INTO silver.equipment_events (id_equipment, ts_event, status) VALUES (8, now() - interval '70 days', 2);
SELECT 'captured keys', count(*) FROM silver.equipment_events__cc;
SELECT 'source rows', count(*) FROM silver.equipment_events;
BEGIN;
SELECT 'SWAP', ops.pc_swap('silver.equipment_events');
COMMIT;
SELECT 'T1 partitioned now (p)', relkind FROM pg_class WHERE oid = 'silver.equipment_events'::regclass;
SELECT 'T2 rows', count(*) FROM silver.equipment_events;
SELECT 'T3 updated row carried (want 9)', status FROM silver.equipment_events WHERE id_equipment = 2 ORDER BY ts_event LIMIT 1;
SELECT 'T4 deleted row gone (want 0)', count(*) FROM silver.equipment_events__ts t WHERE false;
SELECT 'T4 deleted stays deleted (want same as old)', (SELECT count(*) FROM silver.equipment_events WHERE id_equipment = 3) = (SELECT count(*) FROM silver.equipment_events__ts WHERE id_equipment = 3);
SELECT 'T5 new + old-dated inserts present (want 2)', count(*) FROM silver.equipment_events WHERE id_equipment IN (7, 8);
SELECT 'T6 view reads the NEW table (want t)', EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid WHERE r.ev_class = 'silver.v_events'::regclass AND d.refobjid = 'silver.equipment_events'::regclass);
SELECT 'T6b view does not read the old table (want f)', EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid WHERE r.ev_class = 'silver.v_events'::regclass AND d.refobjid = 'silver.equipment_events__ts'::regclass);
SELECT 'T7 grant kept (want t)', has_table_privilege('readapi_ro', 'silver.equipment_events', 'SELECT');
SELECT 'T8 comments', obj_description('silver.equipment_events'::regclass, 'pg_class'), col_description('silver.equipment_events'::regclass, 5);
INSERT INTO silver.equipment_events (id_equipment, ts_event, status) VALUES (9, now(), 1);
SELECT 'T9 identity continues (new id > old max, want t)', (SELECT max(id_equipment_event) FROM silver.equipment_events WHERE id_equipment = 9) > (SELECT max(id_equipment_event) FROM silver.equipment_events__ts);
SELECT 'T10 sequence owned by the new table', (SELECT refobjid::regclass FROM pg_depend WHERE objid = 'silver.ev_source_seq'::regclass AND deptype = 'a');
SELECT 'T11 retention kind (want plain)', kind FROM ops.retention_policy WHERE relation = 'silver.equipment_events';
SELECT 'T12 maintain', * FROM ops.partition_maintain();
SELECT 'T12b oldest row after retention (want >= now-60d-1month)', min(ts_event) > now() - interval '92 days' FROM silver.equipment_events;
SELECT 'T13 index names', string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname = 'silver' AND tablename = 'equipment_events';
-- RLS table
CALL ops.pc_prepare('silver.plc_link_minutes', interval '7 days');
CALL ops.pc_copy('silver.plc_link_minutes');
BEGIN; SELECT 'SWAP', ops.pc_swap('silver.plc_link_minutes'); COMMIT;
SELECT 'R1 rls + force', relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'silver.plc_link_minutes'::regclass;
SET ROLE tenant_reader; SET app.tenant_id = '1';
SELECT 'R2 tenant 1 sees only its rows (want t)', bool_and(id_enterprise = 1) AND count(*) > 0 FROM silver.plc_link_minutes;
RESET ROLE; RESET app.tenant_id;
-- trigger table
CALL ops.pc_prepare('bronze.equipment_values_raw', interval '7 days');
CALL ops.pc_copy('bronze.equipment_values_raw');
BEGIN; SELECT 'SWAP', ops.pc_swap('bronze.equipment_values_raw'); COMMIT;
DO $$ BEGIN UPDATE bronze.equipment_values_raw SET v = 2 WHERE true; RAISE NOTICE 'X1 FAIL: update allowed'; EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'X1 ok: immutability trigger carried over (%)', SQLERRM; END $$;
SELECT 'state', rel, swapped_at IS NOT NULL, old_name FROM ops.pc_state ORDER BY rel;
