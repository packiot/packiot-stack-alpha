\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION serving.production_health(idequipment integer)
 RETURNS SETOF serving.production_health_row LANGUAGE sql STABLE AS $function$
WITH this_week AS (
  SELECT (date_trunc('week', now() AT TIME ZONE s.timezone) + s.week_begin * INTERVAL '1 second') AT TIME ZONE 'UTC' AS week_start
    FROM equipments eq LEFT JOIN sites s ON eq.id_site = s.id_site WHERE id_equipment = idEquipment)
SELECT id_equipment, sum(net) AS net, sum(target) AS target, (sum(net)/(sum(target)+ 1))::NUMERIC(5,1) AS status_overview
  FROM equipment_oee_shift ers WHERE ers.id_equipment = idEquipment AND ts_value >= (SELECT week_start FROM this_week) AND ts_value < now()
 GROUP BY 1 ORDER BY 1;
$function$;
ALTER TYPE serving.production_health_row ALTER ATTRIBUTE status_overview TYPE numeric(5,1);
COMMIT;
