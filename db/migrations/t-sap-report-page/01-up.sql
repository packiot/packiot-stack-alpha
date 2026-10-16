-- t-sap-report-page — menu entry + i18n for the native SAP shift report page (Neopac).
-- Target: the analytics DB read-api serves from (packiot_analytics; config.pages, identity.user_roles,
-- config.translations). NOT auto-applied.
--
-- WHY: front4's legacy "SAP report" (development: CustomPages/Neopac/SapReport) was a URL-only page with
-- an enterprise api_key in the bundle; the only menu entry Neopac had was pages.id_page 66 "06-HU-SAP",
-- a PowerBI report (PowerBI is decommissioned on the new stack → that entry renders a dead shell).
-- front4 now ships /sap-report on read-api (datasets sap-report-lines / sap-report, tenant from the
-- caller's credential). This migration reuses the EXISTING per-tenant menu mechanism
-- (config.pages + identity.user_roles.permissions->desktop->screen[].code, rendered by
-- serving.v_menu_per_user_role) instead of a front4 tenant-id branch:
--
--   1. one config.pages row  {URL:/sap-report, menu_group 4 (Reports)}, list_of_enterprises = the tenants
--      whose report config opts into SAP (serving.report_config(..)->>'family' = 'sap_de') — by config,
--      not by a hard-coded enterprise id. Idempotent: matched on page_info->>'URL'.
--   2. the page code is granted to exactly the roles that already hold the legacy SAP report (code 66)
--      in those tenants — the same audience, no widening. Roles without 66 get it via CS role editing.
--   3. front4 i18n keys (ON CONFLICT DO NOTHING — never overwrites a human edit). hu-HU column labels are
--      the legacy page's Hungarian headers (accent typos õ→ő fixed).
--
-- Reversible: rollback.sql removes the grant, the page row and the keys (tagged updated_by).

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $sap$
DECLARE
  v_page    integer;
  v_tenants integer[];
BEGIN
  SELECT coalesce(array_agg(DISTINCT cd.id_enterprise ORDER BY cd.id_enterprise), ARRAY[]::integer[])
    INTO v_tenants
    FROM core.client_descriptors cd
   WHERE serving.report_config(cd.id_enterprise)->>'family' = 'sap_de';

  SELECT id_page INTO v_page FROM config.pages WHERE page_info->>'URL' = '/sap-report' LIMIT 1;
  IF v_page IS NULL THEN
    SELECT coalesce(max(id_page), 0) + 1 INTO v_page FROM config.pages;
    INSERT INTO config.pages (id_page, list_of_enterprises, page_info, default_piot_page)
    VALUES (v_page, v_tenants,
            jsonb_build_object('URL', '/sap-report', 'name', 'SAP Report',
                               'label', jsonb_build_object('en-US', 'SAP Report', 'hu-HU', 'SAP riport',
                                                           'de-DE', 'SAP-Bericht', 'pt-BR', 'Relatório SAP',
                                                           'pl-PL', 'Raport SAP'),
                               'menu_group', 4, 'page_order', 1),
            false);
  ELSE
    UPDATE config.pages SET list_of_enterprises = v_tenants WHERE id_page = v_page;
  END IF;

  -- Grant to the roles that already see the legacy SAP report (code 66), in SAP tenants only.
  UPDATE identity.user_roles ur
     SET permissions = jsonb_set(ur.permissions, '{desktop,screen}',
                                 (ur.permissions->'desktop'->'screen')
                                   || jsonb_build_array(jsonb_build_object('code', v_page, 'write', false)))
   WHERE ur.id_enterprise = ANY(v_tenants)
     AND jsonb_typeof(ur.permissions->'desktop'->'screen') = 'array'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(ur.permissions->'desktop'->'screen') s
                  WHERE s->>'code' = '66')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ur.permissions->'desktop'->'screen') s
                      WHERE s->>'code' = v_page::text);

  RAISE NOTICE 't-sap-report-page: page % scoped to tenants %', v_page, v_tenants;
END
$sap$;

INSERT INTO config.translations (language_tag, app, namespace, key, value, updated_at, updated_by)
SELECT t.lang, 'front4', 'common', t.key, t.value, now(), 't-sap-report-page'
  FROM (VALUES
    ('en-US', 'sap_report', 'SAP Report'),
    ('hu-HU', 'sap_report', 'SAP riport'),
    ('de-DE', 'sap_report', 'SAP-Bericht'),
    ('pt-BR', 'sap_report', 'Relatório SAP'),
    ('pl-PL', 'sap_report', 'Raport SAP'),
    ('en-US', 'sap_day_shift', 'Day | Shift 1'),
    ('hu-HU', 'sap_day_shift', 'Nappal | Műszak 1'),
    ('de-DE', 'sap_day_shift', 'Tag | Schicht 1'),
    ('pt-BR', 'sap_day_shift', 'Dia | Turno 1'),
    ('pl-PL', 'sap_day_shift', 'Dzień | Zmiana 1'),
    ('en-US', 'sap_night_shift', 'Night | Shift 2'),
    ('hu-HU', 'sap_night_shift', 'Éjszaka | Műszak 2'),
    ('de-DE', 'sap_night_shift', 'Nacht | Schicht 2'),
    ('pt-BR', 'sap_night_shift', 'Noite | Turno 2'),
    ('pl-PL', 'sap_night_shift', 'Noc | Zmiana 2'),
    ('en-US', 'sap_report_not_available', 'The SAP report is not enabled for this enterprise.'),
    ('hu-HU', 'sap_report_not_available', 'Az SAP riport ennél a vállalatnál nincs engedélyezve.'),
    ('de-DE', 'sap_report_not_available', 'Der SAP-Bericht ist für dieses Unternehmen nicht aktiviert.'),
    ('pt-BR', 'sap_report_not_available', 'O relatório SAP não está habilitado para esta empresa.'),
    ('pl-PL', 'sap_report_not_available', 'Raport SAP nie jest włączony dla tego przedsiębiorstwa.'),
    ('en-US', 'sap_report_unknown_line', 'Line not found'),
    ('hu-HU', 'sap_report_unknown_line', 'A sor nem található'),
    ('de-DE', 'sap_report_unknown_line', 'Linie nicht gefunden'),
    ('pt-BR', 'sap_report_unknown_line', 'Linha não encontrada'),
    ('pl-PL', 'sap_report_unknown_line', 'Nie znaleziono linii'),
    ('en-US', 'sap_col_line', 'Line'),
    ('hu-HU', 'sap_col_line', 'Line'),
    ('de-DE', 'sap_col_line', 'Linie'),
    ('pt-BR', 'sap_col_line', 'Linha'),
    ('pl-PL', 'sap_col_line', 'Linia'),
    ('en-US', 'sap_col_shift', 'Shift'),
    ('hu-HU', 'sap_col_shift', 'Shift'),
    ('de-DE', 'sap_col_shift', 'Schicht'),
    ('pt-BR', 'sap_col_shift', 'Turno'),
    ('pl-PL', 'sap_col_shift', 'Zmiana'),
    ('en-US', 'sap_col_shift_hrs', 'Shift hrs'),
    ('hu-HU', 'sap_col_shift_hrs', 'Shift hrs'),
    ('de-DE', 'sap_col_shift_hrs', 'Schichtzeit'),
    ('pt-BR', 'sap_col_shift_hrs', 'Horário do turno'),
    ('pl-PL', 'sap_col_shift_hrs', 'Godziny zmiany'),
    ('en-US', 'sap_col_day', 'Day'),
    ('hu-HU', 'sap_col_day', 'Day'),
    ('de-DE', 'sap_col_day', 'Tag'),
    ('pt-BR', 'sap_col_day', 'Dia'),
    ('pl-PL', 'sap_col_day', 'Dzień'),
    ('en-US', 'sap_col_job', 'Job'),
    ('hu-HU', 'sap_col_job', 'Job'),
    ('de-DE', 'sap_col_job', 'Auftrag'),
    ('pt-BR', 'sap_col_job', 'Ordem'),
    ('pl-PL', 'sap_col_job', 'Zlecenie'),
    ('en-US', 'sap_col_gross', 'Gross'),
    ('hu-HU', 'sap_col_gross', 'Gross'),
    ('de-DE', 'sap_col_gross', 'Brutto'),
    ('pt-BR', 'sap_col_gross', 'Bruto'),
    ('pl-PL', 'sap_col_gross', 'Brutto'),
    ('en-US', 'sap_col_net', 'Net'),
    ('hu-HU', 'sap_col_net', 'Net'),
    ('de-DE', 'sap_col_net', 'Netto'),
    ('pt-BR', 'sap_col_net', 'Líquido'),
    ('pl-PL', 'sap_col_net', 'Netto'),
    ('en-US', 'sap_col_production_time', 'Production time [h]'),
    ('hu-HU', 'sap_col_production_time', 'Gyártási idő [ó]'),
    ('de-DE', 'sap_col_production_time', 'Produktionszeit [h]'),
    ('pt-BR', 'sap_col_production_time', 'Tempo de produção [h]'),
    ('pl-PL', 'sap_col_production_time', 'Czas produkcji [h]'),
    ('en-US', 'sap_col_setup_time', 'Setup time [h]'),
    ('hu-HU', 'sap_col_setup_time', 'Beállítási idő [ó]'),
    ('de-DE', 'sap_col_setup_time', 'Rüstzeit [h]'),
    ('pt-BR', 'sap_col_setup_time', 'Tempo de setup [h]'),
    ('pl-PL', 'sap_col_setup_time', 'Czas przezbrojenia [h]'),
    ('en-US', 'sap_col_technical_failure', 'Technical failure [h]'),
    ('hu-HU', 'sap_col_technical_failure', 'Műszaki hiba [ó]'),
    ('de-DE', 'sap_col_technical_failure', 'Technische Störung [h]'),
    ('pt-BR', 'sap_col_technical_failure', 'Falha técnica [h]'),
    ('pl-PL', 'sap_col_technical_failure', 'Awaria techniczna [h]'),
    ('en-US', 'sap_col_planned_maintenance', 'Planned maintenance [h]'),
    ('hu-HU', 'sap_col_planned_maintenance', 'Tervezett karb. [ó]'),
    ('de-DE', 'sap_col_planned_maintenance', 'Geplante Wartung [h]'),
    ('pt-BR', 'sap_col_planned_maintenance', 'Manutenção planejada [h]'),
    ('pl-PL', 'sap_col_planned_maintenance', 'Planowana konserwacja [h]'),
    ('en-US', 'sap_col_material_problem', 'Material problem [h]'),
    ('hu-HU', 'sap_col_material_problem', 'Anyagprobléma [ó]'),
    ('de-DE', 'sap_col_material_problem', 'Materialproblem [h]'),
    ('pt-BR', 'sap_col_material_problem', 'Problema de material [h]'),
    ('pl-PL', 'sap_col_material_problem', 'Problem z materiałem [h]'),
    ('en-US', 'sap_col_unjustified_time', 'Unjustified time [h]'),
    ('hu-HU', 'sap_col_unjustified_time', 'Nem indokolt idő [ó]'),
    ('de-DE', 'sap_col_unjustified_time', 'Nicht begründete Zeit [h]'),
    ('pt-BR', 'sap_col_unjustified_time', 'Tempo não justificado [h]'),
    ('pl-PL', 'sap_col_unjustified_time', 'Czas nieuzasadniony [h]'),
    ('en-US', 'sap_col_total_dt', 'Total DT [h]'),
    ('hu-HU', 'sap_col_total_dt', 'Total DT [ó]'),
    ('de-DE', 'sap_col_total_dt', 'Stillstand gesamt [h]'),
    ('pt-BR', 'sap_col_total_dt', 'Parada total [h]'),
    ('pl-PL', 'sap_col_total_dt', 'Przestój łącznie [h]'),
    ('en-US', 'sap_col_job_start', 'Job start'),
    ('hu-HU', 'sap_col_job_start', 'Job Start'),
    ('de-DE', 'sap_col_job_start', 'Auftragsbeginn'),
    ('pt-BR', 'sap_col_job_start', 'Início da ordem'),
    ('pl-PL', 'sap_col_job_start', 'Początek zlecenia'),
    ('en-US', 'sap_col_shift_number', 'Shift number'),
    ('hu-HU', 'sap_col_shift_number', 'Műszak száma'),
    ('de-DE', 'sap_col_shift_number', 'Schichtnummer'),
    ('pt-BR', 'sap_col_shift_number', 'Número do turno'),
    ('pl-PL', 'sap_col_shift_number', 'Numer zmiany'),
    ('en-US', 'export_csv', 'Export CSV'),
    ('hu-HU', 'export_csv', 'CSV exportálása'),
    ('de-DE', 'export_csv', 'CSV exportieren'),
    ('pt-BR', 'export_csv', 'Exportar CSV'),
    ('pl-PL', 'export_csv', 'Eksportuj CSV')
  ) AS t(lang, key, value)
ON CONFLICT DO NOTHING;

COMMIT;
