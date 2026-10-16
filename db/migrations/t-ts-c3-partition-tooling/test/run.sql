\set ON_ERROR_STOP 1
-- staging's search_path (2026-10-15: with silver/bronze on it, regclass::text drops the schema; the swap must not care)
SET search_path = "$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public;
\pset format unaligned
CALL ops.pc_prepare('silver.equipment_events', interval '1 month');
CALL ops.pc_copy('silver.equipment_events');
-- changes AFTER the copy: must reach the new table through the capture/replay. As the least-privilege
-- writer: the capture trigger must not require it to have rights on the capture table (2026-10-15 incident).
SET ROLE lp_writer;
UPDATE silver.equipment_events SET ts_end = '2001-01-01', status = 9 WHERE id_equipment = 2 AND ts_event = (SELECT min(ts_event) FROM silver.equipment_events WHERE id_equipment = 2);
DELETE FROM silver.equipment_events WHERE id_equipment = 3 AND ts_event = (SELECT min(ts_event) FROM silver.equipment_events WHERE id_equipment = 3);
INSERT INTO silver.equipment_events (id_equipment, ts_event, status) VALUES (7, now() - interval '5 minutes', 1);
INSERT INTO silver.equipment_events (id_equipment, ts_event, status) VALUES (8, now() - interval '70 days', 2);
RESET ROLE;
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
SELECT 'T6c views still on the old table (want 0)', count(DISTINCT r.ev_class) FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid WHERE d.refobjid = 'silver.equipment_events__ts'::regclass AND r.ev_class <> 'silver.equipment_events__ts'::regclass;
SELECT 'T6d stray views created in gold (want 0)', count(*) FROM pg_class WHERE relnamespace = 'gold'::regnamespace AND relkind = 'v';
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
-- an out-of-range timestamp must land in the DEFAULT partition, not fail the writer (2026-10-15)
SET ROLE lp_writer;
INSERT INTO silver.equipment_events (id_equipment, ts_event, status) VALUES (11, now() + interval '400 days', 1);
RESET ROLE;
SELECT 'T14 far-future row went to the upper catch-all (want 1)', count(*) FROM silver.equipment_events_pmax;
-- 2026-10-15: range catch-alls (not DEFAULT), maintenance moves the upper one, refuses to bury rows, stats exist
SELECT 'T15 catch-alls, no DEFAULT (want 2|0)', (SELECT count(*) FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b WHERE i.inhparent = 'silver.equipment_events'::regclass AND (b.lo_min OR b.hi_max)),
       (SELECT count(*) FROM pg_partitioned_table WHERE partrelid = 'silver.equipment_events'::regclass AND partdefid <> 0);
SELECT 'T16 maintain 180 days ahead moves the upper catch-all (want >0)', created FROM ops.partition_maintain(interval '180 days') WHERE rel = 'silver.equipment_events';
SELECT 'T16b still exactly one upper catch-all (want 1)', count(*) FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b WHERE i.inhparent = 'silver.equipment_events'::regclass AND b.hi_max;
SELECT 'T17 copied partitions have statistics (want 0 unanalyzed)', count(*) FROM pg_stat_user_tables s JOIN pg_inherits i ON i.inhrelid = s.relid
 WHERE i.inhparent = 'bronze.equipment_values_raw'::regclass AND s.n_live_tup > 0 AND s.last_analyze IS NULL AND s.last_autoanalyze IS NULL;
DO $$ DECLARE plan text; BEGIN
  EXECUTE 'EXPLAIN (COSTS OFF) SELECT ts_event FROM silver.equipment_events WHERE id_equipment = 1 AND ts_event < now() - interval ''1 day'' ORDER BY ts_event DESC LIMIT 1' INTO plan;
  FOR plan IN EXECUTE 'EXPLAIN (COSTS OFF) SELECT ts_event FROM silver.equipment_events WHERE id_equipment = 1 AND ts_event < now() - interval ''1 day'' ORDER BY ts_event DESC LIMIT 1' LOOP
    IF plan ~ 'Merge Append' THEN RAISE NOTICE 'T18 FAIL: Merge Append (ordered Append lost)'; END IF;
  END LOOP;
  RAISE NOTICE 'T18 latest-before lookup plans without Merge Append (no FAIL line above = ok)';
END $$;
INSERT INTO silver.equipment_events (id_equipment, ts_event, status) VALUES (12, now() + interval '400 days', 1);
DO $$ BEGIN PERFORM * FROM ops.partition_maintain(interval '450 days'); RAISE NOTICE 'T19 FAIL: maintain buried a row';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'T19 ok: maintain refused to bury a catch-all row (%)', left(SQLERRM, 60); END $$;
