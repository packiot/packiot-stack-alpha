-- Rollback for 01-oee-score.sql (drops the added attributes, restores the running-time-weighted fn).
BEGIN;
DROP FUNCTION serving.oee_score(integer, timestamptz, timestamptz);
ALTER TYPE serving.oee_score_row DROP ATTRIBUTE ideal_production, DROP ATTRIBUTE available_time;
CREATE OR REPLACE FUNCTION serving.oee_score(in_id_enterprise integer, _tsstart timestamp with time zone, _tsend timestamp with time zone)
 RETURNS SETOF oee_score_row
 LANGUAGE sql
 STABLE
AS $function$
  SELECT eq.id_enterprise, rs.id_equipment, min(rs.ts_value), max(rs.ts_end),
    -- canonical: OEE re-derived from summed factors weighted by running_time
    CASE WHEN sum(rs.running_time)>0
      THEN (sum(rs.oee_a*rs.running_time)/sum(rs.running_time))
         * (sum(rs.oee_p*rs.running_time)/sum(rs.running_time))
         * (sum(rs.oee_q*rs.running_time)/sum(rs.running_time)) ELSE 0 END AS oee,
    CASE WHEN sum(rs.running_time)>0 THEN sum(rs.oee_a*rs.running_time)/sum(rs.running_time) ELSE 0 END AS oee_a,
    CASE WHEN sum(rs.running_time)>0 THEN sum(rs.oee_p*rs.running_time)/sum(rs.running_time) ELSE 0 END AS oee_p,
    CASE WHEN sum(rs.running_time)>0 THEN sum(rs.oee_q*rs.running_time)/sum(rs.running_time) ELSE 0 END AS oee_q,
    sum(rs.gross), sum(rs.net), sum(rs.running_time)
  FROM gold.equipment_oee_shift rs JOIN core.equipments eq ON eq.id_equipment=rs.id_equipment
  WHERE eq.id_enterprise = in_id_enterprise AND rs.ts_value >= _tsstart AND rs.ts_value < _tsend AND rs.running_time > 0
  GROUP BY eq.id_enterprise, rs.id_equipment;
$function$

	;
COMMIT;
