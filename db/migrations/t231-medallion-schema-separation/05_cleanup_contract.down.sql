-- t231 · PHASE 5 (CLEANUP / CONTRACT) — reversal.
-- Restore purge_analytics_plain to reference the public gold shim views. (No
-- shim was dropped in the up, so there is nothing else to reverse.)
CREATE OR REPLACE PROCEDURE public.purge_analytics_plain(IN job_id integer, IN config jsonb)
LANGUAGE plpgsql AS $procedure$
  BEGIN
    DELETE FROM public.equipment_oee_hourly        WHERE ts_value < now() - interval '90 days';
    DELETE FROM public.equipment_oee_shift         WHERE ts_value < now() - interval '90 days';
    DELETE FROM public.equipment_events_cpac_shadow WHERE ts_event < now() - interval '90 days';
  END;
$procedure$;
