-- Fix operator "two LINHAS" (task #161): enrich sites/areas/lines in
-- v_entities_per_user_role_operator with the correct per-site packml_topic
-- (+ id_site on areas, id_area/id_site on lines), derived from each level's
-- machines' packml_register topics. The operator SideBar nests the tree by
-- packml_topic prefixes; the view previously emitted bare {id,name} for these
-- levels, so the client's name-only topic heuristic gave two same-named areas
-- (bispharma's "LINHAS" under sites SP and bisnagoSP) the SAME derived topic and
-- rendered them both under one site. Attaching the real per-site topic here makes
-- each LINHAS nest under its own site. Purely additive (extra jsonb fields).
CREATE OR REPLACE VIEW v_entities_per_user_role_operator AS
SELECT v.id_enterprise,
    v.id_enterprise AS id_user_role,
    e.nm_enterprise AS nm_user_role,
    v.enterprise,
    -- SITES: + ENTERPRISE/SITE topic prefix (segments 0-1) from a child machine.
    COALESCE((
      SELECT jsonb_agg(s.elem || jsonb_build_object('packml_topic', d.topic) ORDER BY (s.elem->>'id')::int)
      FROM jsonb_array_elements(v.sites) s(elem)
      LEFT JOIN LATERAL (
        SELECT split_part(pr.packml_topic, '/', 1) || '/' || split_part(pr.packml_topic, '/', 2) AS topic
        FROM equipments eq
        JOIN packml_register pr ON pr.id_equipment = eq.id_equipment AND pr.active = true
        WHERE eq.id_site = (s.elem->>'id')::int AND pr.packml_topic IS NOT NULL
        LIMIT 1
      ) d ON true
    ), v.sites) AS sites,
    -- AREAS: + id_site + ENTERPRISE/SITE/AREA topic prefix (segments 0-2). This
    -- disambiguates same-named areas across sites (bispharma's two "LINHAS").
    COALESCE((
      SELECT jsonb_agg(a.elem || jsonb_build_object('id_site', d.id_site, 'packml_topic', d.topic) ORDER BY (a.elem->>'id')::int)
      FROM jsonb_array_elements(v.areas) a(elem)
      LEFT JOIN LATERAL (
        SELECT eq.id_site,
          split_part(pr.packml_topic, '/', 1) || '/' || split_part(pr.packml_topic, '/', 2) || '/' || split_part(pr.packml_topic, '/', 3) AS topic
        FROM equipments eq
        JOIN packml_register pr ON pr.id_equipment = eq.id_equipment AND pr.active = true
        WHERE eq.id_area = (a.elem->>'id')::int AND pr.packml_topic IS NOT NULL
        LIMIT 1
      ) d ON true
    ), v.areas) AS areas,
    -- LINES: + id_area/id_site + the line's OWN packml_register topic (tp=3 lines
    -- carry a 4-segment topic).
    COALESCE((
      SELECT jsonb_agg(l.elem || jsonb_build_object('id_area', eq.id_area, 'id_site', eq.id_site, 'packml_topic', pr.packml_topic) ORDER BY (l.elem->>'id')::int)
      FROM jsonb_array_elements(v.lines) l(elem)
      LEFT JOIN equipments eq ON eq.id_equipment = (l.elem->>'id')::int
      LEFT JOIN packml_register pr ON pr.id_equipment = eq.id_equipment AND pr.active = true
    ), v.lines) AS lines,
    v.sectors,
    v.machines,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'id_equipment', eq.id_equipment, 'name', eq.nm_equipment, 'packml_topic', pr.packml_topic) ORDER BY eq.id_equipment) AS jsonb_agg
      FROM equipments eq
      LEFT JOIN packml_register pr ON pr.id_equipment = eq.id_equipment AND pr.active = true
      WHERE eq.id_enterprise = v.id_enterprise AND eq.tp_equipment = 1
    ), '[]'::jsonb) AS equipments,
    '[]'::jsonb AS shifts,
    '[]'::jsonb AS teams
FROM v_operator_entities_2 v
JOIN enterprises e ON e.id_enterprise = v.id_enterprise;
