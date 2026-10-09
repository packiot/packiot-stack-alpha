-- t265 part 2 — same bug class: purge_analytics_plain (daily TimescaleDB retention
-- job) still DELETEs FROM public.equipment_events_cpac_shadow, a shim dropped in
-- t261e. It hasn't failed yet only because its last run (15:36) preceded the t261e
-- drop; the NEXT daily run would error (relation does not exist), silently halting
-- ALL retention (90-day purge of cpac_shadow + the gold OEE grains). This IS the
-- cpac_shadow retention flagged in the necessity audit — it already exists, it was
-- just pointing at the dropped public shim. Repoint public → silver.
CREATE OR REPLACE PROCEDURE public.purge_analytics_plain(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
AS $procedure$
  BEGIN
    DELETE FROM gold.equipment_oee_hourly           WHERE ts_value < now() - interval '90 days';
    DELETE FROM gold.equipment_oee_shift            WHERE ts_value < now() - interval '90 days';
    DELETE FROM silver.equipment_events_cpac_shadow WHERE ts_event < now() - interval '90 days';
  END;
$procedure$;
