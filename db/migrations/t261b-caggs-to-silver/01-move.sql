-- t261b — move the 4 EvSchema=public continuous aggregates → silver (they are
-- silver-layer aggregates over silver facts). Zero-gap expand/contract: SET SCHEMA
-- + create a transient public shim view over each, all in ONE transaction, so both
-- the pre-deploy stream-engine (reads public.<cagg> via EvSchema) and read-api
-- (reads bare → silver-first search_path → silver.<cagg> directly) work throughout.
--
-- After the stream-engine deploy (deriver.go reads ca_discrete_changes_1s via
-- SilverSchema %[3]s; uns.go reads agg_equipment_values_1hour via GrainSchema %[6]s),
-- the public shims are droppable (a separate contract step, hardproofed like the dim
-- shims). agg_equipment_values_1min + ca_equipment_boxes_1s are read only by read-api
-- (transparent) — moved for consistency. Real-time caggs, 0 refresh-policy jobs, so
-- SET SCHEMA is catalog-only; no refresh wiring to update.
BEGIN;
ALTER MATERIALIZED VIEW public.agg_equipment_values_1min  SET SCHEMA silver;
ALTER MATERIALIZED VIEW public.agg_equipment_values_1hour SET SCHEMA silver;
ALTER MATERIALIZED VIEW public.ca_discrete_changes_1s     SET SCHEMA silver;
ALTER MATERIALIZED VIEW public.ca_equipment_boxes_1s      SET SCHEMA silver;

CREATE VIEW public.agg_equipment_values_1min  AS SELECT * FROM silver.agg_equipment_values_1min;
CREATE VIEW public.agg_equipment_values_1hour AS SELECT * FROM silver.agg_equipment_values_1hour;
CREATE VIEW public.ca_discrete_changes_1s     AS SELECT * FROM silver.ca_discrete_changes_1s;
CREATE VIEW public.ca_equipment_boxes_1s      AS SELECT * FROM silver.ca_equipment_boxes_1s;
COMMIT;
