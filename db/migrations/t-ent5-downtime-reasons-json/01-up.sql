-- t-ent5-downtime-reasons-json — make Bispharma (ent 5) stops JUSTIFIABLE.
--
-- SYMPTOM (demo rehearsal 2026-09-24): front4 Downtimes "Editar Evento" opens but Máquina /
-- Categoria have NO options → no stop can be justified → the reason Pareto can never fill.
-- ROOT CAUSE: the dialog reads the per-equipment reasons JSON core.equipments.downtime_reasons
-- (refdata `equipment-downtime-reasons`). CPACK: 62/62 equipments have it; ent5: 0/128 —
-- t-ent5-downtime-reason-catalog seeded only the NORMALIZED catalog (core.downtime_reason).
-- SHAPE: front4 (DialogEdit.jsx) reads the legacy Hasura shape — name{'en-US'} /
-- description{'en-US'} at machine, category and subcategory level; the analytics JSON uses
-- `code`. Both key sets are written so either reader works. (CPACK's JSON has only `code`
-- → front4's dialog is broken for CPACK too — separate follow-up; operator is its path.)
-- LANGUAGE: reason labels are CLIENT CONTENT; Bispharma presents in pt-BR and front4 reads
-- the 'en-US' key for these labels, so the Portuguese text is stored there (and in pt-BR).
-- The catalog labels (core.downtime_reason) get pt-BR too.
-- STRUCTURE: a member (tp=1) lists itself as the one machine; a line (tp=3) lists each of
-- its members, so a stop can be attributed to the station that caused it. Machine code =
-- <line>-<member> (CPACK convention, e.g. L3-RMH).
BEGIN;

CREATE TEMP TABLE _pt(code text PRIMARY KEY, pt text) ON COMMIT DROP;
INSERT INTO _pt VALUES
  ('EQUIP_FAIL','Falha de Equipamento'), ('MECH','Falha Mecânica'), ('ELEC','Falha Elétrica'),
  ('PNEUM','Pneumática / Hidráulica'), ('SENSOR','Sensor / Atuador'),
  ('PROC_ISSUE','Problema de Processo'), ('QUAL_REJ','Rejeição de Qualidade'),
  ('SETUP_ERR','Erro de Setup'), ('TOOL_WEAR','Desgaste de Ferramenta'),
  ('IDLE','Ociosidade / Espera'), ('WAIT_MAT','Aguardando Material'),
  ('WAIT_OP','Aguardando Operador'), ('WAIT_QA','Aguardando Liberação da Qualidade'),
  ('PLANNED','Parada Planejada'), ('BREAK','Pausa Programada'), ('MEETING','Reunião de Equipe'),
  ('PREV_MAINT','Manutenção Preventiva'), ('CHANGEOVER','Troca de Produto / Setup');

-- catalog labels → pt-BR (label + label_i18n; en-US kept in label_i18n)
UPDATE core.downtime_reason r SET label = p.pt,
       label_i18n = coalesce(r.label_i18n::jsonb, '{}'::jsonb) || jsonb_build_object('pt-BR', p.pt)
  FROM _pt p WHERE r.id_enterprise = 5 AND r.code = p.code;

-- the category tree, once
CREATE TEMP TABLE _cats ON COMMIT DROP AS
SELECT jsonb_agg(jsonb_build_object(
         'code', c.code, 'name', jsonb_build_object('en-US', c.code),
         'description', jsonb_build_object('en-US', coalesce(pc.pt, c.label), 'pt-BR', coalesce(pc.pt, c.label)),
         'planned_downtime', c.planned_downtime, 'change_over', c.change_over, 'idle', c.idle,
         'subcategories', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                     'code', s.code, 'name', jsonb_build_object('en-US', s.code),
                     'description', jsonb_build_object('en-US', coalesce(ps.pt, s.label), 'pt-BR', coalesce(ps.pt, s.label)),
                     'planned_downtime', s.planned_downtime, 'change_over', s.change_over, 'idle', s.idle)
                   ORDER BY s.code)
              FROM core.downtime_reason s LEFT JOIN _pt ps ON ps.code = s.code
             WHERE s.id_enterprise = 5 AND s.active AND s.reason_level = 2 AND s.category = c.code), '[]'::jsonb))
       ORDER BY c.code) AS cats
  FROM core.downtime_reason c LEFT JOIN _pt pc ON pc.code = c.code
 WHERE c.id_enterprise = 5 AND c.active AND c.reason_level = 1;

CREATE TEMP TABLE _machine ON COMMIT DROP AS
SELECT m.id_equipment, m.id_parentequipment,
       jsonb_build_object(
         'code', l.nm_equipment || '-' || m.nm_equipment,
         'name', jsonb_build_object('en-US', l.nm_equipment || '-' || m.nm_equipment),
         -- machine description == code ON PURPOSE: front4 DialogEdit.handleChangeCategories
         -- looks the machine up by name['en-US'] === <selected option's LABEL> (a bug — it
         -- should compare the value), so subcategories only load when the two are equal.
         'description', jsonb_build_object('en-US', l.nm_equipment || '-' || m.nm_equipment,
                                           'pt-BR', l.nm_equipment || '-' || m.nm_equipment),
         'categories', (SELECT cats FROM _cats)) AS entry
  FROM core.equipments m JOIN core.equipments l ON l.id_equipment = m.id_parentequipment
 WHERE m.id_enterprise = 5 AND m.tp_equipment = 1;

UPDATE core.equipments e SET downtime_reasons = jsonb_build_array(mm.entry)
  FROM _machine mm WHERE e.id_equipment = mm.id_equipment;
UPDATE core.equipments e SET downtime_reasons = x.arr
  FROM (SELECT id_parentequipment AS id_line, jsonb_agg(entry ORDER BY entry->>'code') arr
          FROM _machine GROUP BY 1) x
 WHERE e.id_equipment = x.id_line AND e.id_enterprise = 5 AND e.tp_equipment = 3;

SELECT tp_equipment, count(*) total, count(*) FILTER (WHERE jsonb_array_length(downtime_reasons::jsonb) > 0) with_reasons
  FROM core.equipments WHERE id_enterprise = 5 GROUP BY 1 ORDER BY 1;
COMMIT;
