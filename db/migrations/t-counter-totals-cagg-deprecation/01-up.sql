-- t-counter-totals-cagg-deprecation — F2 of t-counter-totals-float8 (2026-10-07): the 4 continuous aggregates keep
-- their float4-derived *_val columns, marked DEPRECATED. They are NOT rebuilt.
--
-- DECISION (evidence, staging 2026-10-07, read-only):
--   * the caggs store max(*_val) per bucket: a copy of the float4 totalizer, already rounded above 2^24. All OEE /
--     production math runs on sum(*_incr), which is exact upstream and untouched by the float4 issue.
--   * NOTHING reads those columns: pg_depend shows only equipment_categorical_1hour (built on _1min); the only
--     function that reads counter *_val anywhere is ops.job_data_invariants, and it reads silver (v7: coalesce);
--     pg_stat_statements has no query reading cagg *_val except pg_dump COPYs; repo grep finds no app reader.
--   * rebuilding = drop + recreate + re-materialize ~4.3 GB (equipment_categorical_1min 3.5 GB, agg_1min 625 MB
--     with compressed chunks) on the shared DB, for zero readers. Not worth the risk.
--   So: deprecate in place. A future rebuild (for any other reason) should drop these columns or switch them to
--   max(coalesce(*_total, *_val)); exact totalizers are read from silver.equipment_values(_labeled).*_total.
-- Comment-only: no data, no plan change; COMMENT takes a brief lock on the view only (3 s lock_timeout).
-- The original comment text is kept after the DEPRECATED prefix; rollback.sql restores it exactly.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

COMMENT ON COLUMN silver.agg_equipment_values_1min.net_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.net_production_total instead). max(net_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.gross_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.gross_production_total instead). max(gross_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.scrap_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.scrap_total instead). max(scrap_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.net_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.net_production_total instead). max(net_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.gross_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.gross_production_total instead). max(gross_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.scrap_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.scrap_total instead). max(scrap_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.net_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.net_production_total instead). Representative net totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.gross_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.gross_production_total instead). Representative gross totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.scrap_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.scrap_total instead). Representative scrap totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.net_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.net_production_total instead). Representative net totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.gross_production_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.gross_production_total instead). Representative gross totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.scrap_val IS 'DEPRECATED (float4, rounds above 16,777,216; read silver.equipment_values.scrap_total instead). Representative scrap totalizer value in the bucket (count).';

COMMIT;
