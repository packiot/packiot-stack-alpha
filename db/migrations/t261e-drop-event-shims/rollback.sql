-- t261e rollback — recreate the transient public event-table shims over silver.
CREATE VIEW public.data_quality_event          AS SELECT * FROM silver.data_quality_event;
CREATE VIEW public.equipment_events_man         AS SELECT * FROM silver.equipment_events_man;
CREATE VIEW public.equipment_events_cpac_shadow AS SELECT * FROM silver.equipment_events_cpac_shadow;
CREATE VIEW public.equipment_events_low_speed   AS SELECT * FROM silver.equipment_events_low_speed;
