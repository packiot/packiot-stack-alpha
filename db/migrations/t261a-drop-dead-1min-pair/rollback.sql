-- t261a rollback — recreate the dead 1min pair (empty table + its view).
CREATE TABLE IF NOT EXISTS public.equipment_values_1min (
    ts_value timestamp with time zone,
    id_equipment integer,
    val double precision
);
CREATE OR REPLACE VIEW public.agg_equipment_values_1min_t AS
 SELECT equipment_values_1min.ts_value,
        equipment_values_1min.id_equipment,
        equipment_values_1min.val
   FROM equipment_values_1min;
