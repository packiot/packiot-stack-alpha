-- serving.oee_score — unbiased, uncapped aggregate (2026-09-29 clamp/bias audit).
-- Was: A, P, Q each averaged WEIGHTED BY RUNNING TIME and rows with running_time=0
-- dropped. Running-time weighting over-weights high-availability shifts (a shift at
-- A=1 for 8 h and one at A=0.1 average to 0.92 instead of the true 0.55): served OEE
-- was 5-35 points high (ent5 L56 63.6% vs 27.9%). Dropping running_time=0 rows also
-- removed their production from gross/net (CPACK 30 d: 118 line-shifts, 696k units).
-- Now ratios of SUMS, the same definition as serving.oee_score_by_team:
--   oee = Σnet/Σideal_production, A = Σrunning/Σavailable, Q = Σnet/Σgross,
--   P = Σgross·Σavailable/(Σideal_production·Σrunning)   (so oee = A·P·Q exactly)
-- No upper cap: P > 1 means the configured ideal speed is too low — a signal the
-- UI shows, not something the data hides. available_time and ideal_production are
-- returned so clients aggregate ACROSS lines the same way (never average ratios).
-- gross/net are real (float4) in gold: summed as float8 to keep precision.
ALTER TYPE serving.oee_score_row
  ADD ATTRIBUTE available_time double precision,
  ADD ATTRIBUTE ideal_production double precision;
CREATE OR REPLACE FUNCTION serving.oee_score(in_id_enterprise integer, _tsstart timestamp with time zone, _tsend timestamp with time zone)
 RETURNS SETOF serving.oee_score_row
 LANGUAGE sql
 STABLE
AS $function$
  SELECT eq.id_enterprise, rs.id_equipment, min(rs.ts_value), max(rs.ts_end),
    coalesce(sum(rs.net::float8) / nullif(sum(rs.ideal_production), 0), 0)                                        AS oee,
    coalesce(sum(rs.running_time)::float8 / nullif(sum(rs.available_time), 0), 0)                                 AS oee_a,
    coalesce(sum(rs.gross::float8) * sum(rs.available_time)
             / nullif(sum(rs.ideal_production) * sum(rs.running_time), 0), 0)                                     AS oee_p,
    coalesce(sum(rs.net::float8) / nullif(sum(rs.gross::float8), 0), 0)                                           AS oee_q,
    sum(rs.gross::float8), sum(rs.net::float8), sum(rs.running_time)::float8,
    sum(rs.available_time)::float8, sum(rs.ideal_production)
  FROM gold.equipment_oee_shift rs JOIN core.equipments eq ON eq.id_equipment = rs.id_equipment
  WHERE eq.id_enterprise = in_id_enterprise AND rs.ts_value >= _tsstart AND rs.ts_value < _tsend
  GROUP BY eq.id_enterprise, rs.id_equipment;
$function$;
