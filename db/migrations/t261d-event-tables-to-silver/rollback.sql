-- t261d rollback — move the 4 event tables back to public (drop shims first).
BEGIN;
DROP VIEW IF EXISTS public.data_quality_event;
DROP VIEW IF EXISTS public.equipment_events_man;
DROP VIEW IF EXISTS public.equipment_events_cpac_shadow;
DROP VIEW IF EXISTS public.equipment_events_low_speed;
ALTER TABLE silver.data_quality_event           SET SCHEMA public;
ALTER TABLE silver.equipment_events_man          SET SCHEMA public;
ALTER TABLE silver.equipment_events_cpac_shadow  SET SCHEMA public;
ALTER TABLE silver.equipment_events_low_speed    SET SCHEMA public;
COMMIT;
