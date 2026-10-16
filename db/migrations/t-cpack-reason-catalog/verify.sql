-- t-cpack-reason-catalog / verify.sql — read-only checks, run AFTER 01-up.sql (or inside the
-- same BEGIN … ROLLBACK dry run). Every row prints label|value…; expected values in comments.

-- V1. every category code used by CPACK events in the last 30 days resolves:
--     in_dim     = an active level-1 core.downtime_reason row (ent 3) with that code
--     linked     = that row is linked (junction) to the event's own equipment
--     in_tree    = the event's equipment tree has machine = cd_machine with category name = cd_category
--     expected: codes = in_dim = linked = in_tree (29 on 2026-09-29), events_* all equal.
WITH ev AS (
  SELECT id_equipment, cd_machine, cd_category, planned_downtime, change_over, idle
    FROM silver.equipment_events
   WHERE id_enterprise = 3 AND ts_event >= now() - interval '30 days' AND cd_category IS NOT NULL
), r AS (
  SELECT ev.*,
         EXISTS (SELECT 1 FROM core.downtime_reason d WHERE d.id_enterprise = 3 AND d.active
                    AND d.reason_level = 1 AND d.code = ev.cd_category) AS in_dim,
         EXISTS (SELECT 1 FROM core.equipment_downtime_reason j JOIN core.downtime_reason d ON d.id = j.id_reason
                  WHERE j.id_equipment = ev.id_equipment AND j.active AND d.active
                    AND d.reason_level = 1 AND d.code = ev.cd_category) AS linked,
         (SELECT c FROM core.equipments e, jsonb_array_elements(e.downtime_reasons) m, jsonb_array_elements(m->'categories') c
           WHERE e.id_equipment = ev.id_equipment AND jsonb_typeof(e.downtime_reasons) = 'array'
             AND m->>'code' = ev.cd_machine AND c->'name'->>'en-US' = ev.cd_category LIMIT 1) AS tree_cat
    FROM ev
)
SELECT 'V1_codes', count(DISTINCT cd_category) AS codes,
       count(DISTINCT cd_category) FILTER (WHERE in_dim) AS in_dim,
       count(DISTINCT cd_category) FILTER (WHERE linked) AS linked,
       count(DISTINCT cd_category) FILTER (WHERE tree_cat IS NOT NULL) AS in_tree,
       count(*) AS events, count(*) FILTER (WHERE in_dim) AS events_in_dim,
       count(*) FILTER (WHERE linked) AS events_linked,
       count(*) FILTER (WHERE tree_cat IS NOT NULL) AS events_in_tree,
       string_agg(DISTINCT cd_category, ',') FILTER (WHERE NOT in_dim OR NOT linked OR tree_cat IS NULL) AS unresolved
  FROM r
UNION ALL
-- V3. flags: event flags vs the flags of the tree node it resolves to (the write path reads
--     them from the tree) and vs the normalized dim row (mode). idle: event text vs tree 'yes'/'no'.
SELECT 'V3_flags', count(*) FILTER (WHERE tree_cat IS NOT NULL),
       count(*) FILTER (WHERE tree_cat IS NOT NULL AND planned_downtime IS NOT DISTINCT FROM (tree_cat->>'planned_downtime')::boolean
                                                  AND change_over IS NOT DISTINCT FROM (tree_cat->>'change_over')::boolean
                                                  AND idle IS NOT DISTINCT FROM (tree_cat->>'idle')),
       count(*) FILTER (WHERE tree_cat IS NOT NULL AND planned_downtime IS DISTINCT FROM (tree_cat->>'planned_downtime')::boolean),
       count(*) FILTER (WHERE tree_cat IS NOT NULL AND change_over IS DISTINCT FROM (tree_cat->>'change_over')::boolean),
       count(*) FILTER (WHERE tree_cat IS NOT NULL AND idle IS DISTINCT FROM (tree_cat->>'idle')),
       count(*) FILTER (WHERE in_dim AND
            (SELECT d.planned_downtime IS DISTINCT FROM r.planned_downtime OR d.change_over IS DISTINCT FROM r.change_over
               FROM core.downtime_reason d
              WHERE d.id_enterprise = 3 AND d.active AND d.reason_level = 1 AND d.code = r.cd_category)),
       NULL::bigint, NULL::bigint, NULL
  FROM r;
-- columns of V3_flags: resolved | all_match | planned_diff | changeover_diff | idle_diff | dim_planned_or_co_diff

-- V2. per-line catalog, to diff against the same query on legacy (see PR): one row per
--     analytics equipment carrying a tree — base topic, #machine groups, #category entries,
--     #distinct category codes, #subcategory entries, #junction links, md5 of the tree.
SELECT 'V2_line', p.packml_topic, e.tp_equipment,
       jsonb_array_length(e.downtime_reasons),
       (SELECT count(*) FROM jsonb_array_elements(e.downtime_reasons) m, jsonb_array_elements(m->'categories') c),
       (SELECT count(DISTINCT c->'name'->>'en-US') FROM jsonb_array_elements(e.downtime_reasons) m, jsonb_array_elements(m->'categories') c),
       (SELECT count(*) FROM jsonb_array_elements(e.downtime_reasons) m, jsonb_array_elements(m->'categories') c,
               jsonb_array_elements(coalesce(c->'subcategories','[]')) s),
       (SELECT count(*) FROM core.equipment_downtime_reason j JOIN core.downtime_reason d ON d.id = j.id_reason
         WHERE j.id_equipment = e.id_equipment AND d.reason_level = 1),
       md5(e.downtime_reasons::text)
  FROM core.equipments e
  JOIN core.packml_register p ON p.id_equipment = e.id_equipment AND p.active AND p.packml_topic !~ '/(Admin|Status)/'
 WHERE e.id_enterprise = 3 AND e.downtime_reasons IS NOT NULL
 ORDER BY 2;
