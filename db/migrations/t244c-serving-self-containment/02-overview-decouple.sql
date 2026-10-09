-- ============================================================================
-- t244c :: Piece B — decouple serving.overview_takt / overview_scrap_rate from
-- the empty stub TABLES public.v_13_overview_takt / v_13_overview_partial_scrap_rate.
-- Those stubs have NO writer and were never computed (permanently 0-row Hasura
-- placeholders). Behavior-preserving self-contained EMPTY result: project the
-- real equipment dimension fenced to the tenant with WHERE false — identical
-- column names+types, guaranteed 0 rows (matches the stubs' never-computed state).
-- ADDITIVE: pure CREATE OR REPLACE (signatures unchanged).
-- ============================================================================
SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION serving.overview_takt(p_id_enterprise integer)
RETURNS TABLE(id_equipment integer, id_enterprise integer, id_site integer, avg_speed integer)
LANGUAGE sql STABLE AS $function$
  SELECT e.id_equipment, e.id_enterprise, e.id_site, NULL::integer AS avg_speed
  FROM equipments e
  WHERE e.id_enterprise = p_id_enterprise AND false
$function$;

CREATE OR REPLACE FUNCTION serving.overview_scrap_rate(p_id_enterprise integer)
RETURNS TABLE(cd_equipment character varying, id_enterprise integer, id_site integer, id_equipment integer,
              gross double precision, net double precision, scrap double precision, scrap_rate numeric)
LANGUAGE sql STABLE AS $function$
  SELECT e.cd_equipment, e.id_enterprise, e.id_site, e.id_equipment,
         NULL::double precision AS gross, NULL::double precision AS net,
         NULL::double precision AS scrap, NULL::numeric AS scrap_rate
  FROM equipments e
  WHERE e.id_enterprise = p_id_enterprise AND false
$function$;
