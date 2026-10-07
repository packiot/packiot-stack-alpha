-- t-adr0061-p3b-entities-hierarchy-ids — ADR-0061 P3: the operator builds its navigation tree from IDS.
--
-- serving.v_entities_per_user_role_operator (edge-api /session entities + read-api /v1/entities-per-user-role)
-- already gives areas {id_site} and lines {id_area, id_site}. Sectors and equipments carried no parent at all,
-- so the SPA reconstructed the tree by splitting packml_topic strings. This adds, as EXTRA JSON KEYS (old clients
-- ignore them; every column, row and existing key is unchanged):
--   sectors[]    + id_parentequipment, id_area, id_site
--   equipments[] + id_parentequipment, id_area, id_site
--   lines[]      + id_parentequipment
-- Body = the LIVE definition (pg_get_viewdef on the staging copy, 2026-10-07) with only those additions.
-- security_invoker is restated explicitly so the replace cannot drop it (t280).

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE VIEW serving.v_entities_per_user_role_operator WITH (security_invoker = on) AS
 SELECT v.id_enterprise,
    v.id_enterprise AS id_user_role,
    e.nm_enterprise AS nm_user_role,
    v.enterprise,
    COALESCE(( SELECT jsonb_agg((s.elem || jsonb_build_object('packml_topic', d.topic)) ORDER BY ((s.elem ->> 'id'::text))::integer) AS jsonb_agg
           FROM (jsonb_array_elements(v.sites) s(elem)
             LEFT JOIN LATERAL ( SELECT ((split_part((pr.packml_topic)::text, '/'::text, 1) || '/'::text) || split_part((pr.packml_topic)::text, '/'::text, 2)) AS topic
                   FROM (equipments eq
                     JOIN topic_routing pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))
                  WHERE ((eq.id_site = ((s.elem ->> 'id'::text))::integer) AND (pr.packml_topic IS NOT NULL))
                 LIMIT 1) d ON (true))), v.sites) AS sites,
    COALESCE(( SELECT jsonb_agg((a.elem || jsonb_build_object('id_site', d.id_site, 'packml_topic', d.topic)) ORDER BY ((a.elem ->> 'id'::text))::integer) AS jsonb_agg
           FROM (jsonb_array_elements(v.areas) a(elem)
             LEFT JOIN LATERAL ( SELECT eq.id_site,
                    ((((split_part((pr.packml_topic)::text, '/'::text, 1) || '/'::text) || split_part((pr.packml_topic)::text, '/'::text, 2)) || '/'::text) || split_part((pr.packml_topic)::text, '/'::text, 3)) AS topic
                   FROM (equipments eq
                     JOIN topic_routing pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))
                  WHERE ((eq.id_area = ((a.elem ->> 'id'::text))::integer) AND (pr.packml_topic IS NOT NULL))
                 LIMIT 1) d ON (true))), v.areas) AS areas,
    COALESCE(( SELECT jsonb_agg((l.elem || jsonb_build_object('id_area', eq.id_area, 'id_site', eq.id_site, 'packml_topic', pr.packml_topic, 'id_parentequipment', eq.id_parentequipment)) ORDER BY ((l.elem ->> 'id'::text))::integer) AS jsonb_agg
           FROM ((jsonb_array_elements(v.lines) l(elem)
             LEFT JOIN equipments eq ON ((eq.id_equipment = ((l.elem ->> 'id'::text))::integer)))
             LEFT JOIN topic_routing pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))), v.lines) AS lines,
    COALESCE(( SELECT jsonb_agg((sc.elem || jsonb_build_object('id_parentequipment', eq.id_parentequipment, 'id_area', eq.id_area, 'id_site', eq.id_site)) ORDER BY ((sc.elem ->> 'id'::text))::integer) AS jsonb_agg
           FROM (jsonb_array_elements(v.sectors) sc(elem)
             LEFT JOIN equipments eq ON ((eq.id_equipment = ((sc.elem ->> 'id'::text))::integer)))), v.sectors) AS sectors,
    v.machines,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'id_equipment', eq.id_equipment, 'name', eq.nm_equipment, 'packml_topic', pr.packml_topic, 'id_parentequipment', eq.id_parentequipment, 'id_area', eq.id_area, 'id_site', eq.id_site) ORDER BY eq.id_equipment) AS jsonb_agg
           FROM (equipments eq
             LEFT JOIN topic_routing pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))
          WHERE ((eq.id_enterprise = v.id_enterprise) AND (eq.tp_equipment = 1))), '[]'::jsonb) AS equipments,
    '[]'::jsonb AS shifts,
    '[]'::jsonb AS teams
   FROM (v_operator_entities_2 v
     JOIN enterprises e ON ((e.id_enterprise = v.id_enterprise)));

COMMIT;
