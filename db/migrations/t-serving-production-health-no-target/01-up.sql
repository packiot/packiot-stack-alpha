-- t-serving-production-health-no-target (2026-10-15, hardproof after the TimescaleDB removal)
-- serving.production_health (read-api dataset overview-production-health, front4 overview gauge) returned
-- status_overview = (Σnet / (Σtarget + 1))::numeric(5,1). For an equipment WITHOUT a production target that is just
-- the week's net production, which passes 9999.9 within days → "numeric field overflow" → HTTP 500. 26 equipments
-- overflowed on staging (Thursday 2026-10-15). Not a clamp (user policy: store raw / uncapped ratios):
--   * no target (Σtarget NULL or <= 0) → status_overview NULL (the ratio is undefined, not huge)
--   * otherwise the same formula, rounded to 1 decimal, in an unconstrained numeric (the row type widened)
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
ALTER TYPE serving.production_health_row ALTER ATTRIBUTE status_overview TYPE numeric;
CREATE OR REPLACE FUNCTION serving.production_health(idequipment integer)
 RETURNS SETOF serving.production_health_row
 LANGUAGE sql
 STABLE
AS $function$
WITH this_week AS (
  SELECT (date_trunc('week', now() AT TIME ZONE s.timezone) + s.week_begin * INTERVAL '1 second') AT TIME ZONE 'UTC' AS week_start
    FROM equipments eq
    LEFT JOIN sites s ON eq.id_site = s.id_site
   WHERE id_equipment = idEquipment
)
SELECT id_equipment,
       sum(net) AS net,
       sum(target) AS target,
       CASE WHEN coalesce(sum(target), 0) > 0 THEN round((sum(net) / (sum(target) + 1))::numeric, 1) END AS status_overview
  FROM equipment_oee_shift ers
 WHERE ers.id_equipment = idEquipment
   AND ts_value >= (SELECT week_start FROM this_week)
   AND ts_value < now()
 GROUP BY 1
 ORDER BY 1;
$function$;
COMMIT;
