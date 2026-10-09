-- t261c rollback — recreate the transient public cagg shims over silver.
CREATE VIEW public.agg_equipment_values_1min  AS SELECT * FROM silver.agg_equipment_values_1min;
CREATE VIEW public.agg_equipment_values_1hour AS SELECT * FROM silver.agg_equipment_values_1hour;
CREATE VIEW public.ca_discrete_changes_1s     AS SELECT * FROM silver.ca_discrete_changes_1s;
CREATE VIEW public.ca_equipment_boxes_1s      AS SELECT * FROM silver.ca_equipment_boxes_1s;
