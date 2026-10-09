-- t261b rollback — move the 4 caggs back to public (drop the transient shims first).
BEGIN;
DROP VIEW IF EXISTS public.agg_equipment_values_1min;
DROP VIEW IF EXISTS public.agg_equipment_values_1hour;
DROP VIEW IF EXISTS public.ca_discrete_changes_1s;
DROP VIEW IF EXISTS public.ca_equipment_boxes_1s;
ALTER MATERIALIZED VIEW silver.agg_equipment_values_1min  SET SCHEMA public;
ALTER MATERIALIZED VIEW silver.agg_equipment_values_1hour SET SCHEMA public;
ALTER MATERIALIZED VIEW silver.ca_discrete_changes_1s     SET SCHEMA public;
ALTER MATERIALIZED VIEW silver.ca_equipment_boxes_1s      SET SCHEMA public;
COMMIT;
