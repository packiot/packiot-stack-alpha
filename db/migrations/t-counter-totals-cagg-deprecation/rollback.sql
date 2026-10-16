-- rollback for t-counter-totals-cagg-deprecation: the exact 2026-10-07 comments.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

COMMENT ON COLUMN silver.agg_equipment_values_1min.net_production_val IS 'max(net_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.gross_production_val IS 'max(gross_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.scrap_val IS 'max(scrap_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.net_production_val IS 'max(net_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.gross_production_val IS 'max(gross_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.scrap_val IS 'max(scrap_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.net_production_val IS 'Representative net totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.gross_production_val IS 'Representative gross totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.scrap_val IS 'Representative scrap totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.net_production_val IS 'Representative net totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.gross_production_val IS 'Representative gross totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.scrap_val IS 'Representative scrap totalizer value in the bucket (count).';

COMMIT;
