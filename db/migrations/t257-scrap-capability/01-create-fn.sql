-- t257 — serving.equipment_scrap_capability: per-equipment "does this line/machine
-- have a way to MEASURE scrap?" derived from the counter-register config that the
-- rollup itself uses (line_lead.go COUNTER-ROLE MATRIX). Additive + read-only; does
-- NOT touch oee_score / oee_score_row (sidesteps the #1132 type-change front4 break).
--
-- scrap_measurable = TRUE iff the equipment's counter set can yield scrap:
--   • a DEFECT counter is present            (ProdDefectiveCount → scrap direct), OR
--   • BOTH consumed AND processed present    (gross & net → scrap = gross − net),  OR
--   • BOTH infeed AND outfeed counters set   (scrap = infeed − outfeed).
-- FALSE ⇒ single-source (net-only / gross-only / infeed-only, e.g. FLEXO/SLEEVE): the
-- engine forces gross=net so Quality=100% is an ARTIFACT, not a measured value — the UI
-- should render "no scrap data" rather than a misleading 100%.
--
-- Counter set = the equipment itself PLUS its child machines (line-metered clients put
-- counters on the tp=1 machines under a tp=3 line — line_lead borrows them).
CREATE OR REPLACE FUNCTION serving.equipment_scrap_capability(in_id_enterprise integer)
RETURNS TABLE(id_equipment integer, scrap_measurable boolean)
LANGUAGE sql STABLE AS $function$
  SELECT e.id_equipment,
    ( COALESCE(bool_or(tr.packml_topic ILIKE '%DefectiveCount%'
                    OR tr.packml_topic ILIKE '%defect%'
                    OR tr.packml_topic ILIKE '%scrap%'), false)
      OR ( COALESCE(bool_or(tr.packml_topic ILIKE '%ConsumedCount%'), false)
       AND COALESCE(bool_or(tr.packml_topic ILIKE '%ProcessedCount%'), false) )
      OR ( COALESCE(bool_or(tr.id_infeedcounter  IS NOT NULL), false)
       AND COALESCE(bool_or(tr.id_outfeedcounter IS NOT NULL), false) )
    ) AS scrap_measurable
  FROM core.equipments e
  LEFT JOIN core.topic_routing tr
    ON tr.id_equipment IN (
         SELECT c.id_equipment FROM core.equipments c
          WHERE c.id_parentequipment = e.id_equipment OR c.id_equipment = e.id_equipment)
  WHERE e.id_enterprise = in_id_enterprise AND e.id_area IS NOT NULL
  GROUP BY e.id_equipment;
$function$;
