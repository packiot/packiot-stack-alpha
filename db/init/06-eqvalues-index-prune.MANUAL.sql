-- 06-eqvalues-index-prune.MANUAL.sql — REFACTORED schemas only
-- (F3 public in packiot_shadow; F2 shadow_go_port in packiot). NEVER legacy packiot.public.
--
-- ⚠️  RUN THIS MANUALLY, OUTSIDE ANY TRANSACTION. It is NOT part of the
-- ⚠️  transactional migration (05-…). Every statement here is either
-- ⚠️  DROP INDEX CONCURRENTLY or VACUUM (FULL, …) — both of which PostgreSQL
-- ⚠️  refuses to run inside a transaction block. Run with autocommit on:
-- ⚠️
-- ⚠️      sed 's/__SCH__/public/g' 06-eqvalues-index-prune.MANUAL.sql \
-- ⚠️        | psql -d packiot_shadow -v ON_ERROR_STOP=0
-- ⚠️
-- ⚠️  (do NOT wrap in BEGIN/COMMIT; do NOT run via a knex/DO migration.)
-- ⚠️  IF EXISTS on every drop makes it re-runnable; a CONCURRENTLY drop that is
-- ⚠️  interrupted leaves an INVALID index — just re-run this file to finish it.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY — approved DBA review, TASK 1: prune ~630 MB of dead/redundant indexes on
-- the equipment_values hypertable. Measured on staging packiot_shadow (TSDB 2.27,
-- 29 chunks): total equipment_values index footprint 987 MB → 359 MB. All scan
-- counts below are lifetime totals aggregated across the parent + every chunk
-- index (a hypertable's real scans land on the chunk indexes, not the parent).
--
--   DEAD (0 lifetime scans — pure write amplification):
--     equipment_values_id_equipment_ts_value_id_shift_hour_idx        181 MB
--     equipment_values_id_equipment_ts_value_id_shift_idx             181 MB
--     equipment_values_id_equipment_ts_value_id_production_order_idx   8.6 MB
--     equipment_values_id_production_order_idx                         1.6 MB
--     equipment_values_id_equipment_ts_value_id_order_idx             240 kB
--     equipment_values_id_equipment_ts_value_mode_idx                344 kB
--     equipment_values_id_equipment_ts_value_conversion_factor_idx   240 kB
--     equipment_values_id_equipment_ts_value_signal_quality_idx      240 kB
--     equipment_values_id_equipment_ts_value_id_team_idx             240 kB
--     equipment_values_id_equipment_ts_value_number_cavities_idx     240 kB
--     data_quality_event_ent_detected_idx  (plain table)             384 kB
--
--   PK-REDUNDANT (the PRIMARY KEY (id_equipment, ts_value) already serves these
--   via forward/backward index scan; verified EXPLAIN uses the pkey afterward):
--     equipment_values_id_equipment_idx      (exact dup of pkey cols)   124 MB
--     equipment_values_id_equipment_ts_idx   (DESC variant)             131 MB
--
--   KEPT (hot — DO NOT drop): equipment_values_pkey, …_state (partial),
--     …_ideal_production_speed (partial), …_ts_value_idx, …_time_bucket_idx,
--     …_id_enterprise_idx.
--
-- Reversible: the "ROLLBACK" appendix at the bottom recreates every dropped index.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — drop the per-chunk indexes CONCURRENTLY (online, one at a time).
-- The generator is scoped to chunks of __SCH__.equipment_values via pg_inherits
-- and excludes the primary key, so the two 2-column signatures cannot match any
-- other table's index and can never hit the pkey.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I;', n.nspname, ci.relname)
FROM pg_inherits inh
JOIN pg_class      parent    ON parent.oid = inh.inhparent
JOIN pg_namespace  parentns  ON parentns.oid = parent.relnamespace
JOIN pg_class      chunk     ON chunk.oid = inh.inhrelid
JOIN pg_index      idx       ON idx.indrelid = chunk.oid AND NOT idx.indisprimary
JOIN pg_class      ci        ON ci.oid = idx.indexrelid
JOIN pg_namespace  n         ON n.oid = ci.relnamespace
WHERE parent.relname = 'equipment_values'
  AND parentns.nspname = '__SCH__'
  AND substring(pg_get_indexdef(idx.indexrelid) FROM 'USING .*') IN (
    'USING btree (id_equipment, ts_value DESC, id_shift_hour) WHERE (id_shift_hour IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, id_shift) WHERE (id_shift IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, id_production_order) WHERE (id_production_order IS NOT NULL)',
    'USING btree (id_production_order) WHERE (id_production_order IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, id_order) WHERE (id_order IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, mode) WHERE (mode IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, conversion_factor) WHERE (conversion_factor IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, signal_quality) WHERE (signal_quality IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, id_team) WHERE (id_team IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC, number_cavities) WHERE (number_cavities IS NOT NULL)',
    'USING btree (id_equipment, ts_value DESC)',   -- id_equipment_ts_idx  (PK-redundant, DESC)
    'USING btree (id_equipment, ts_value)'         -- id_equipment_idx     (PK-redundant, exact dup)
  )
\gexec

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — drop the now-childless parent (hypertable) indexes CONCURRENTLY.
-- (Must come AFTER step 1: dropping a parent while chunk children still exist
-- errors with "DROP INDEX CONCURRENTLY does not support dropping multiple objects".)
-- ─────────────────────────────────────────────────────────────────────────────
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_id_shift_hour_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_id_shift_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_id_production_order_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_production_order_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_id_order_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_mode_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_conversion_factor_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_signal_quality_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_id_team_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_value_number_cavities_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_idx;
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.equipment_values_id_equipment_ts_idx;

-- STEP 3 — the plain-table dead index (not a hypertable, single object).
DROP INDEX CONCURRENTLY IF EXISTS __SCH__.data_quality_event_ent_detected_idx;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — one-time compaction (TASK 3 tail). Reclaims the pre-existing bloat and
-- rewrites each small (<50 MB) rollup at its new fillfactor (set in 05-…).
-- VACUUM FULL takes a brief ACCESS EXCLUSIVE lock — run off-peak. 1hour (~49 MB,
-- ~0.2% dead) is intentionally excluded: not bloated, not worth the lock.
-- Measured staging reclamation: area 2008→264 kB, 1day 1832→952 kB,
-- equipment_runtime_shift 11 MB→4.4 MB, production_orders_runtime 28 MB→2.3 MB.
-- ─────────────────────────────────────────────────────────────────────────────
VACUUM (FULL, ANALYZE) __SCH__.area_runtime_shift;
VACUUM (FULL, ANALYZE) __SCH__.equipment_runtime_1day;
VACUUM (FULL, ANALYZE) __SCH__.equipment_runtime_shift;
VACUUM (FULL, ANALYZE) __SCH__.production_orders_runtime;

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK (recreate every dropped index; also CONCURRENTLY, outside a txn).
-- Uncomment + run to fully restore the prior index set.
-- ─────────────────────────────────────────────────────────────────────────────
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_id_shift_hour_idx        ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, id_shift_hour)       WHERE (id_shift_hour IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_id_shift_idx             ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, id_shift)            WHERE (id_shift IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_id_production_order_idx  ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, id_production_order)  WHERE (id_production_order IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_production_order_idx                        ON __SCH__.equipment_values USING btree (id_production_order)                              WHERE (id_production_order IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_id_order_idx             ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, id_order)            WHERE (id_order IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_mode_idx                 ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, mode)                WHERE (mode IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_conversion_factor_idx    ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, conversion_factor)   WHERE (conversion_factor IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_signal_quality_idx       ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, signal_quality)      WHERE (signal_quality IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_id_team_idx              ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, id_team)             WHERE (id_team IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_value_number_cavities_idx      ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC, number_cavities)     WHERE (number_cavities IS NOT NULL);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_idx                               ON __SCH__.equipment_values USING btree (id_equipment, ts_value);
-- CREATE INDEX CONCURRENTLY equipment_values_id_equipment_ts_idx                            ON __SCH__.equipment_values USING btree (id_equipment, ts_value DESC);
-- CREATE INDEX CONCURRENTLY data_quality_event_ent_detected_idx                             ON __SCH__.data_quality_event USING btree (id_enterprise, detected_at DESC);
