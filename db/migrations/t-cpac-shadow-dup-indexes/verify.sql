-- verify for t-cpac-shadow-dup-indexes. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 unique indexes on (id_equipment, ts_event): 1', count(*)
  FROM pg_index i WHERE i.indrelid = 'silver.equipment_events_cpac_shadow'::regclass AND i.indisunique;
SELECT 'V2 the remaining one is the valid PK: t', bool_and(i.indisprimary AND i.indisvalid)
  FROM pg_index i WHERE i.indrelid = 'silver.equipment_events_cpac_shadow'::regclass AND i.indisunique;
SELECT 'V3 dropped indexes absent (incl. INVALID leftovers): 0', count(*)
  FROM pg_class WHERE relname IN ('equipment_events_cpac_shadow_key', 'equipment_events_cpac_shadow_id_equipment_ts_event_idx');
SELECT 'V4 ts_event index kept: t', EXISTS (SELECT 1 FROM pg_class WHERE relname = 'equipment_events_cpac_shadow_ts_event_idx');
SELECT 'V5 all indexes, MB (52 = pkey 40 + ts_event 12 until the reclaim; ~2 after VACUUM FULL)', round(pg_indexes_size('silver.equipment_events_cpac_shadow') / 1048576.0, 1);
-- V6: the deriver's arbiter still resolves (ON CONFLICT inference needs a unique index on exactly
-- these columns; EXPLAIN without ANALYZE plans but never executes). Expect "Conflict Arbiter Indexes:
-- equipment_events_cpac_shadow_pkey" and nothing else on that line.
EXPLAIN (COSTS OFF) INSERT INTO silver.equipment_events_cpac_shadow AS ev (id_equipment, ts_event, status)
VALUES (0, '1970-01-01', 0) ON CONFLICT (id_equipment, ts_event) DO UPDATE SET status = EXCLUDED.status;
