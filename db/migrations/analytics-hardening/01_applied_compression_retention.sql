-- APPLIED on staging (idempotent). Cagg compression + policies + retention +
-- chunk sizing. Reclaimed DB 5,998 -> ~2,810 MB. Safe/reversible.
-- Compression config (segmentby by entity, orderby ts_value DESC) already SET on:
--   ca_discrete_changes_1s, ca_agg_equipment_values_1min/1hour,
--   agg_equipment_values_1min/10min/1hour, agg_area_values_*, agg_site_values_*
-- Policies (auto-manage future chunks):
SELECT add_compression_policy(c, INTERVAL '7 days', if_not_exists=>true)
FROM unnest(ARRAY[
  'ca_discrete_changes_1s','ca_agg_equipment_values_1min','ca_agg_equipment_values_1hour',
  'agg_equipment_values_1min','agg_equipment_values_10min','agg_equipment_values_1hour',
  'agg_area_values_1min','agg_area_values_10min','agg_area_values_1hour',
  'agg_site_values_1min','agg_site_values_10min','agg_site_values_1hour']::regclass[]) c;
-- Retention 90d on fine caggs (aligned to the 90d source retention on equipment_values):
SELECT add_retention_policy(c, INTERVAL '90 days', if_not_exists=>true)
FROM unnest(ARRAY[
  'ca_discrete_changes_1s','ca_agg_equipment_values_1min',
  'agg_equipment_values_1min','agg_equipment_values_10min',
  'agg_area_values_1min','agg_site_values_1min']::regclass[]) c;
-- Chunk sizing:
SELECT set_chunk_time_interval('lab_equipment_values', INTERVAL '1 day');
