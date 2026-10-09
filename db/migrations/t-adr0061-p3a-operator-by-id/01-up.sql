-- t-adr0061-p3a-operator-by-id — ADR-0061 P3 (first slice): the operator's topic-filtered reads get id-based
-- siblings, and the D6 display path exists. ADDITIVE: every v1 object is untouched.
--
-- core.equipment_display_path(id) — D6's computed, human-readable path (enterprise/site/area/…parents…/
--   equipment NAMES). Display only: never parsed, never routed on, so renames stop breaking anything. v1
--   contract fields that carry packml_topic switch to it when topic_routing is dropped (P5).
-- serving.pending_downtime_by_equipment(int[]), serving.events_timeline_by_equipment(int[]) — the read-api
--   /v2 operator routes. They WRAP the live v1 functions (ids → their active register topics → v1), so the
--   rules (thresholds, dedupe, windows) are the same code by construction and cannot drift; the topic column
--   is replaced by display_path. P5 inverts this: the body moves here and v1 is deleted.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION core.equipment_display_path(p_id_equipment integer)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, core, public
AS $$
  WITH RECURSIVE chain AS (
    SELECT e.id_equipment, e.id_parentequipment, e.nm_equipment, 0 AS depth
      FROM equipments e WHERE e.id_equipment = p_id_equipment
    UNION ALL
    SELECT p.id_equipment, p.id_parentequipment, p.nm_equipment, c.depth + 1
      FROM equipments p JOIN chain c ON p.id_equipment = c.id_parentequipment
     WHERE c.depth < 8                                   -- bounded: a parent cycle cannot loop
  )
  SELECT concat_ws('/', en.nm_enterprise, s.nm_site, a.nm_area,
                   (SELECT string_agg(coalesce(nullif(btrim(c.nm_equipment), ''), c.id_equipment::text), '/'
                                      ORDER BY c.depth DESC) FROM chain c))
    FROM equipments e
    LEFT JOIN enterprises en ON en.id_enterprise = e.id_enterprise
    LEFT JOIN sites s        ON s.id_site = e.id_site
    LEFT JOIN areas a        ON a.id_area = e.id_area
   WHERE e.id_equipment = p_id_equipment
$$;
COMMENT ON FUNCTION core.equipment_display_path(integer) IS
  'ADR-0061 D6: human-readable enterprise/site/area/…/equipment NAME path. Display only — never parse or route on it.';

-- the id → register-topic bridge both wrappers use (all of the equipment's active rows: v1 picks the base one)
CREATE OR REPLACE FUNCTION serving.topics_of_equipment(in_id_equipment integer[])
RETURNS character varying[]
LANGUAGE sql STABLE
AS $$
  SELECT coalesce(array_agg(pr.packml_topic), '{}')::character varying[]
    FROM packml_register pr
   WHERE pr.id_equipment = ANY (in_id_equipment) AND pr.active
$$;
COMMENT ON FUNCTION serving.topics_of_equipment(integer[]) IS
  'ADR-0061 P3 bridge (deleted in P5): active register topics of the given equipments, to call a v1 topic-filtered function by id.';

CREATE OR REPLACE FUNCTION serving.pending_downtime_by_equipment(in_id_equipment integer[])
RETURNS TABLE (id_equipment_event bigint, ts_event timestamptz, ts_end timestamptz, duration integer,
               id_equipment integer, id_enterprise integer, display_path text)
LANGUAGE sql STABLE
AS $$
  SELECT d.id_equipment_event, d.ts_event, d.ts_end, d.duration, d.id_equipment, d.id_enterprise,
         core.equipment_display_path(d.id_equipment)
    FROM serving.pending_downtime(serving.topics_of_equipment(in_id_equipment)) d
   ORDER BY d.ts_event DESC
$$;
COMMENT ON FUNCTION serving.pending_downtime_by_equipment(integer[]) IS
  'ADR-0061 P3: id-based serving.pending_downtime (read-api /v2/pending-downtime). Wraps v1 by construction.';

CREATE OR REPLACE FUNCTION serving.events_timeline_by_equipment(in_id_equipment integer[])
RETURNS TABLE (id_equipment_event bigint, ts_event timestamptz, ts_end timestamptz, duration integer,
               id_equipment integer, id_enterprise integer, txt_downtime_notes character varying,
               cd_machine character varying, cd_category character varying, cd_subcategory character varying,
               change_over boolean, desc_category character varying, desc_subcategory character varying,
               display_path text, event_type text, id_order_text character varying, id_production_order bigint,
               production_programmed bigint, custom_field jsonb)
LANGUAGE sql STABLE
AS $$
  SELECT t.id_equipment_event, t.ts_event, t.ts_end, t.duration, t.id_equipment, t.id_enterprise,
         t.txt_downtime_notes, t.cd_machine, t.cd_category, t.cd_subcategory, t.change_over,
         t.desc_category, t.desc_subcategory, core.equipment_display_path(t.id_equipment),
         t.event_type, t.id_order_text, t.id_production_order, t.production_programmed, t.custom_field
    FROM serving.events_timeline(serving.topics_of_equipment(in_id_equipment)) t
$$;
COMMENT ON FUNCTION serving.events_timeline_by_equipment(integer[]) IS
  'ADR-0061 P3: id-based serving.events_timeline (read-api /v2/events-timeline). Wraps v1 by construction (v1 row order kept).';

-- v2 downtime reasons: one row per requested machine/line, no register join (v1's join only mapped topics to
-- equipments). Same LINE-ONLY rule as v1: a member of a downtime_from_lead_machine line gets the line's tree.
CREATE OR REPLACE FUNCTION serving.downtime_reasons_by_equipment(in_id_equipment integer[])
RETURNS TABLE (id_equipment integer, id_enterprise integer, downtime_reasons jsonb, scrap_reasons jsonb, display_path text)
LANGUAGE sql STABLE
AS $$
  SELECT e.id_equipment, e.id_enterprise, r.downtime_reasons, e.scrap_reasons, core.equipment_display_path(e.id_equipment)
    FROM equipments e
    LEFT JOIN equipments l ON l.id_equipment = e.id_parentequipment
         AND l.id_enterprise = e.id_enterprise AND l.tp_equipment = 3
         AND l.downtime_from_lead_machine AND l.active
    JOIN equipments r ON r.id_equipment = COALESCE(l.id_equipment, e.id_equipment)
   WHERE e.id_equipment = ANY (in_id_equipment) AND e.active AND e.tp_equipment IN (1, 3)
$$;
COMMENT ON FUNCTION serving.downtime_reasons_by_equipment(integer[]) IS
  'ADR-0061 P3: id-based downtime/scrap reason trees (read-api /v2/downtime-reasons); proven set-equal to v1 per line scope.';

GRANT EXECUTE ON FUNCTION core.equipment_display_path(integer), serving.topics_of_equipment(integer[]),
  serving.pending_downtime_by_equipment(integer[]), serving.events_timeline_by_equipment(integer[]),
  serving.downtime_reasons_by_equipment(integer[])
  TO readapi_ro, superset_ro, bi_owner;

COMMIT;
