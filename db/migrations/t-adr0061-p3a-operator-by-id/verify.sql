-- verify for t-adr0061-p3a-operator-by-id. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
-- 2 × (v1 + v2) per line scope in one statement: lift the role's statement_timeout for this session only.
-- Staging (70 line scopes, ~3 s per v1 call) takes ~14 min — longer than an SSM session; run it detached or
-- in OFFSET/LIMIT batches of the scopes table (2026-10-07 apply did 4 × 18).
SET statement_timeout = '10min';
-- For every LINE: the topic set the operator sends (its base topic + every topic under it, operator
-- childTopics) vs the ids behind those topics. v2 must return exactly v1's rows, in v1's order.
CREATE TEMP TABLE scopes AS
  SELECT l.id_equipment AS line, array_agg(DISTINCT pr.packml_topic)::varchar[] AS topics,
         array_agg(DISTINCT pr.id_equipment) AS ids
    FROM packml_register l
    JOIN packml_register pr ON pr.active AND (pr.packml_topic = l.packml_topic OR pr.packml_topic LIKE l.packml_topic || '/%')
    JOIN equipments e ON e.id_equipment = l.id_equipment AND e.tp_equipment = 3
   WHERE l.active AND l.id_unit IS NULL
   GROUP BY l.id_equipment;
SELECT 'V0 line scopes checked: >0', count(*) FROM scopes;
SELECT 'V1 pending_downtime rows v1 vs v2 differ (scopes): 0', count(*) FROM scopes s
 WHERE ARRAY(SELECT (d.id_equipment_event, d.id_equipment) FROM serving.pending_downtime(s.topics) d)
    IS DISTINCT FROM ARRAY(SELECT (d.id_equipment_event, d.id_equipment) FROM serving.pending_downtime_by_equipment(s.ids) d);
SELECT 'V2 events_timeline rows v1 vs v2 differ (scopes): 0', count(*) FROM scopes s
 WHERE ARRAY(SELECT (t.id_equipment_event, t.id_equipment, t.event_type, t.cd_category) FROM serving.events_timeline(s.topics) t)
    IS DISTINCT FROM ARRAY(SELECT (t.id_equipment_event, t.id_equipment, t.event_type, t.cd_category) FROM serving.events_timeline_by_equipment(s.ids) t);
SELECT 'V3 rows compared (pending, timeline): >0', (SELECT count(*) FROM scopes s, serving.pending_downtime(s.topics)),
       (SELECT count(*) FROM scopes s, serving.events_timeline(s.topics));
SELECT 'V6 downtime_reasons v1 (read-api SQL) vs v2 differ (scopes): 0', count(*) FROM scopes s WHERE
 ARRAY(SELECT DISTINCT (e.id_equipment, r.downtime_reasons::text, e.scrap_reasons::text)
   FROM equipments e JOIN packml_register p ON p.id_equipment = e.id_equipment AND (p.id_unit = e.id_equipment OR (p.id_unit IS NULL AND e.tp_equipment = 3))
   LEFT JOIN equipments l ON l.id_equipment = e.id_parentequipment AND l.id_enterprise = e.id_enterprise AND l.tp_equipment = 3 AND l.downtime_from_lead_machine AND l.active
   JOIN equipments r ON r.id_equipment = COALESCE(l.id_equipment, e.id_equipment)
  WHERE p.packml_topic = ANY(s.topics) AND p.active ORDER BY 1)
 IS DISTINCT FROM
 ARRAY(SELECT DISTINCT (d.id_equipment, d.downtime_reasons::text, d.scrap_reasons::text) FROM serving.downtime_reasons_by_equipment(s.ids) d ORDER BY 1);
SELECT 'V4 every active equipment has a display path (missing): 0', count(*) FROM equipments e
 WHERE e.active AND coalesce(core.equipment_display_path(e.id_equipment), '') = '';
SELECT 'V5 readapi_ro can execute the v2 functions: t|t', has_function_privilege('readapi_ro', 'serving.pending_downtime_by_equipment(integer[])', 'EXECUTE'),
       has_function_privilege('readapi_ro', 'serving.events_timeline_by_equipment(integer[])', 'EXECUTE');
