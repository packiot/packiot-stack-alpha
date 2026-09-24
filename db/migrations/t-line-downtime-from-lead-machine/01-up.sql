-- t-line-downtime-from-lead-machine — line-level downtime for clients whose stops are
-- minted on MEMBER machines (counters-only CPAC live derivation, e.g. Bispharma ent 5).
--
-- SYMPTOM (2026-09-24): Superset "Paradas" tab ("Paradas por motivo", "Últimos eventos")
-- = "No results" for Bispharma. Those charts are LINE-level (filter equipment_label LIKE
-- '% (line)', the 2026-09-21 fix to avoid machine+line double counting). CPACK has events
-- ON its lines (legacy mirror); Bispharma's deriver mints them only on members → no line rows.
-- WHY A FLAG, NOT A HEURISTIC: a generic "attribute lead-machine stops without a line twin"
-- rule was measured against CPACK: 206/848 lead stops lack an exact line twin and 118 of
-- them OVERLAP an existing line stop → it would double-count and silently change CPACK's
-- line figures. So attribution is explicit per line: core.equipments.downtime_from_lead_machine
-- (default false → CPACK byte-identical). Onboarding sets it for counters-only clients.
-- VIEW: bi.downtimes gains a UNION ALL branch that re-labels the line's LEAD MACHINE stops as
-- the line ('<line> (line)', id_equipment = the line); member rows are untouched, so
-- machine-level analysis is unchanged. Tenant fence unchanged: the new branch joins the
-- RLS-protected equipments row of the LINE, and a lead machine belongs to its line's tenant.
-- Owner is asserted to bi_owner (the NOBYPASSRLS definer) after the replace; tables are
-- schema-qualified.
BEGIN;

ALTER TABLE core.equipments ADD COLUMN IF NOT EXISTS downtime_from_lead_machine boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN core.equipments.downtime_from_lead_machine IS
  'LINE (tp_equipment=3) only: attribute its lead_machine''s stops to the line in line-level downtime views (bi.downtimes). Set for clients whose events are minted on member machines (counters-only CPAC live derivation). Default false.';

UPDATE core.equipments SET downtime_from_lead_machine = true
 WHERE id_enterprise = 5 AND tp_equipment = 3 AND lead_machine IS NOT NULL
   AND downtime_from_lead_machine IS DISTINCT FROM true;

CREATE OR REPLACE VIEW bi.downtimes AS
SELECT
    eq.id_enterprise,
    ev.id_equipment_event AS id_downtime,
    ev.id_equipment,
    eq.nm_equipment,
    ev.cd_category, ev.cd_subcategory, ev.desc_category, ev.desc_subcategory,
    ev.ts_event AS ts_value, ev.ts_end, ev.duration, ev.planned_downtime, ev.change_over, ev.status,
    CASE ev.status WHEN 6 THEN 'Running' WHEN 10 THEN 'Stopped' ELSE ev.status::text END AS status_label,
    COALESCE(ev.desc_category,
             CASE WHEN ev.planned_downtime THEN 'Planned'
                  WHEN ev.change_over      THEN 'Changeover'
                  ELSE 'Unjustified' END) AS reason,
    eq.nm_equipment || CASE eq.tp_equipment
             WHEN 3 THEN ' (line)' WHEN 1 THEN ' (machine)'
             WHEN 2 THEN ' (sector)' ELSE '' END AS equipment_label
FROM silver.equipment_events ev
JOIN core.equipments eq ON eq.id_equipment = ev.id_equipment
WHERE ev.status <> 6
UNION ALL
-- line attribution of lead-machine stops (flagged lines only)
SELECT
    ln.id_enterprise,
    ev.id_equipment_event AS id_downtime,
    ln.id_equipment,
    ln.nm_equipment,
    ev.cd_category, ev.cd_subcategory, ev.desc_category, ev.desc_subcategory,
    ev.ts_event AS ts_value, ev.ts_end, ev.duration, ev.planned_downtime, ev.change_over, ev.status,
    CASE ev.status WHEN 6 THEN 'Running' WHEN 10 THEN 'Stopped' ELSE ev.status::text END AS status_label,
    COALESCE(ev.desc_category,
             CASE WHEN ev.planned_downtime THEN 'Planned'
                  WHEN ev.change_over      THEN 'Changeover'
                  ELSE 'Unjustified' END) AS reason,
    ln.nm_equipment || ' (line)' AS equipment_label
FROM core.equipments ln
JOIN silver.equipment_events ev ON ev.id_equipment = ln.lead_machine
WHERE ln.tp_equipment = 3 AND ln.downtime_from_lead_machine
  AND ev.status <> 6;
-- Created by the migrating superuser (bi_owner has no USAGE on core/silver, which is
-- only needed at CREATE time — at runtime the owner's TABLE grants apply). CREATE OR
-- REPLACE keeps the owner, and this line ASSERTS it: the definer must stay the
-- NOBYPASSRLS bi_owner or superset_ro would read through RLS.
ALTER VIEW bi.downtimes OWNER TO bi_owner;

COMMIT;
