\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 status_overview type (want numeric)', format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
 WHERE a.attrelid = 'serving.production_health_row'::regclass AND a.attname = 'status_overview';
-- V2: every equipment with shift rows this week evaluates without error (the old version raised for 26 on staging)
SELECT 'V2 equipments evaluated', count(*), count(*) FILTER (WHERE h.status_overview IS NULL) AS no_target
  FROM (SELECT DISTINCT id_equipment FROM gold.equipment_oee_shift WHERE ts_value >= date_trunc('week', now()) - interval '1 day') e,
       LATERAL serving.production_health(e.id_equipment) h;
