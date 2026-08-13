-- 0012-r2b-operator-entities-enrich.sql — enrich v_operator_entities so the
-- operator SPA renders tp=3 LINES (not topic-exploded machines) in the sidebar
-- AND can resolve ids for PO/downtime writes (APPLIED new-prod 2026-08-12).
--
-- Builds on 0012-r2-promote-v-operator-entities.sql (canonical name).
--
-- Root cause this fixes:
--   * Sidebar bound its "line" level to entities.equipments (tp=1 machines ×
--     active packml topics) — CPACK operators saw ~42 machine nodes instead of
--     the 20 tp=3 lines. The clean `lines` array existed but lacked the two
--     fields the frontend needs to USE it: `packml_topic` (tree filter + PO
--     lookup) and `id_equipment` (node selection sets lineId).
--   * resolveEquipmentIds() (SelectPo/ChangeJob/ModalReplacePO/AddManualEvent)
--     matches sites/areas/lines on id_site / id_area / id_equipment — but the
--     jsonb only exposed a generic `id`, so every PO/downtime write resolved
--     idEquipment = undefined (400 on create-and-start). Adding the properly
--     named id_* keys makes writes resolve.
--
-- Additive only: same 7-column signature (dependents + refdata unaffected);
-- lines/sectors packml_topic uses the SAME LIMIT-1 active packml_register row as
-- v_operator_po_list_setup_4.topic, so operator findCurrentPo(topic) still
-- matches. machines left exactly as-is (refdata getMachines reads .machines).
--
-- Frontend companion: operator VariablesContext.setEntities now binds
-- lineOptions to entities.lines (not equipments); AuthContext auto-selects the
-- first LINE topic; the topic-exploded equipments are routed to
-- localStorage['machines'] to keep endpoints.js childTopics() working.

CREATE OR REPLACE VIEW v_operator_entities AS
SELECT
    e.id_enterprise,
    jsonb_build_array(jsonb_build_object('id', e.id_enterprise, 'name', e.nm_enterprise)) AS enterprise,
    COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id', s.id_site, 'id_site', s.id_site, 'name', s.nm_site))
        FROM sites s WHERE s.id_enterprise = e.id_enterprise
    ), '[]'::jsonb) AS sites,
    COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id', a.id_area, 'id_area', a.id_area, 'id_site', a.id_site, 'name', a.nm_area))
        FROM areas a JOIN sites s ON s.id_site = a.id_site
        WHERE s.id_enterprise = e.id_enterprise
    ), '[]'::jsonb) AS areas,
    COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id', eq.id_equipment, 'id_equipment', eq.id_equipment,
            'id_site', eq.id_site, 'id_area', eq.id_area,
            'name', eq.nm_equipment, 'position', eq."position",
            'packml_topic', (SELECT pr.packml_topic FROM packml_register pr
                             WHERE pr.id_equipment = eq.id_equipment AND pr.active = true LIMIT 1)))
        FROM equipments eq WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 3
    ), '[]'::jsonb) AS lines,
    COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id', eq.id_equipment, 'id_equipment', eq.id_equipment,
            'id_site', eq.id_site, 'id_area', eq.id_area,
            'name', eq.nm_equipment, 'position', eq."position",
            'packml_topic', (SELECT pr.packml_topic FROM packml_register pr
                             WHERE pr.id_equipment = eq.id_equipment AND pr.active = true LIMIT 1)))
        FROM equipments eq WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 2
    ), '[]'::jsonb) AS sectors,
    COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id', eq.id_equipment, 'name', eq.nm_equipment, 'position', eq."position"))
        FROM equipments eq WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 1
    ), '[]'::jsonb) AS machines
FROM enterprises e;

-- Rollback: re-apply the pre-enrichment body (bare sites/areas + lines without
-- id_site/id_area/id_equipment/packml_topic) from 0012-r2-promote-…, if ever
-- needed. Purely additive keys, so rollback is only relevant to undo the
-- companion frontend change.
