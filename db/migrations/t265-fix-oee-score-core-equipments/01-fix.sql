-- t265 — P0 fix: serving.oee_score references dropped public.equipments.
--
-- serving.oee_score is the canonical per-equipment A·P·Q OEE function (read-api
-- "oee-score-full" dataset, repointed in #218). Its body pinned `public.equipments`
-- which was dropped in the #258/#261 medallion de-shim epic → the function errors
-- (relation "public.equipments" does not exist) on every call, taking down the
-- front4/operator OEE-score display on staging.
--
-- Root cause: the de-shim audit grepped SERVICE code for `public.<obj>` refs but
-- NOT DB function/view BODIES. Every sibling serving fn references `equipments`
-- UNqualified (resolves to core.equipments via the silver-first search_path), so
-- only this one — which hard-qualified `public.` — broke.
--
-- Fix: point the join at core.equipments (the real table). Verified: returns
-- 17 enterprise-3 rows, factors in [0,1], identity oee=a·p·q exact.
--
-- (This function's canonical source was not present in the main-tree repo — it
-- lived only in a stale worktree copy of analytics-clean-schema/07_p2_serving_layer.sql
-- — so this migration is now its codified source of truth. See the audit ledger's
-- codification-drift note.)
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
$function$;
