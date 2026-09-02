-- f3-topology-nav-backfill.sql
-- ===========================================================================
-- Idempotent CONFIG/TOPOLOGY backfill for F3 (packiot_analytics), the plane we
-- are consolidating to. ADDITIVE ONLY — never touches telemetry (equipment_values,
-- caggs, uns_*, events). Three independent, self-contained sections (H3/H4/H6),
-- each with an inline read-only verification query.
--
-- WHY EACH GAP EXISTS (root cause), so a re-run/reviewer understands intent:
--
--   H3  equipments.id_parentequipment NULL for all 62 CPACK (ent-3) rows.
--       The descriptor-driven onboarding pipeline (generate -> apply-register ->
--       cutover) only ever writes packml_register (topic -> id_equipment); it
--       never writes the equipments table, and the client descriptor's equipment
--       model carries NO parent field. The cell/line/machine hierarchy is encoded
--       ONLY in the packml topic path (CPACK/SC/LINHAS/L5/BREYER => machine BREYER
--       under line L5), but the generator never parses it into id_parentequipment.
--       The column is only ever settable via the manual csadmin per-machine form /
--       line-config UI, which bulk onboarding bypasses -> left NULL.
--       => Backfill each machine (tp=1) to its parent line/cell (tp=3/2) by
--          resolving the packml topic path.
--
--   H4  client_descriptors EMPTY in F3 -> csadmin Sensor-config + Onboarding
--       descriptor views blank. The descriptor is authored/written on F1
--       (packiot, the legacy write-master) by the onboarding generate/capture
--       flow, but nothing mirrors client_descriptors F1 -> F3 (refsync excludes
--       it; analytics-sync only replays operator actions). => Port CPACK's real
--       descriptor (and the sandbox twin's) F1 -> F3 via dblink.
--
--   H6  front4 sidebar nav EMPTY for all tenants. v_menu_per_user_role returns 0
--       rows because (a) the pages dimension is EMPTY in F3 (never seeded; it is
--       empty on F1 too — the real rows live only in legacy prod packiot40) and
--       (b) role 3 (operator-cpack-staging) has permissions.desktop.screen = [].
--       The view joins exploded desktop.screen[].code = pages.id_page, so BOTH
--       must be populated. => Seed the pages dimension (ported from legacy prod
--       packiot40, CPACK = legacy ent 1, remapped to F3 ent 3 + sandbox 2000003)
--       and set the operator role's desktop.screen to CPACK's authentic non-super
--       screen set (legacy "Supervisor" role 247).
--
-- HOW TO RUN (against F3, which has the dblink extension installed). The F1 DSN
-- is only needed for section H4:
--   psql -h 10.10.10.89 -U postgres -d packiot_analytics \
--     -v f1_dsn="host=10.10.10.89 port=5432 dbname=packiot user=postgres password=$F1_PW" \
--     -f db/cutover/f3-topology-nav-backfill.sql
--
-- SIBLING-AGENT COORDINATION: this file owns DATA backfill only. A sibling owns
-- relations/indexes/functions (production_information, equipment_events_man index,
-- h_piot fns) — no overlap here.
-- ===========================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- H3 — Backfill equipments.id_parentequipment for CPACK (ent-3) from packml topics
-- ---------------------------------------------------------------------------
-- Resolution: a machine's canonical node topic is one level below its parent
-- line/cell topic (e.g. CPACK/SC/LINHAS/L5/BREYER -> parent CPACK/SC/LINHAS/L5;
-- CPACK/SC/CELULA1/CER400/CER400 -> parent CPACK/SC/CELULA1/CER400). We match the
-- machine's clean topic to the topic obtained by stripping its last '/segment'
-- and take that parent topic's id_equipment (which must be a line/cell, tp 3/2).
--
-- "clean" = drop metric/leaf/count topics (Admin|Status|Count|/Unit|/<digits>/)
-- and the 4 malformed placeholder rows (CPACK_STAGING/SC/CELULA1// etc.). The
-- malformed rows block nothing: every one of the 42 machines is covered by a
-- well-formed CPACK/ topic, so all 42 resolve. The 20 lines/cells (tp=3) stay
-- NULL by design — they are the roots of the equipment hierarchy (area is above).
WITH clean AS (
  SELECT DISTINCT packml_topic AS t, id_equipment AS eq
    FROM packml_register
   WHERE id_enterprise = 3
     AND id_equipment IS NOT NULL
     AND packml_topic !~ '(Admin|Status|Count|/Unit|/[0-9]+/)'
     AND packml_topic NOT LIKE 'CPACK\_STAGING%'
),
resolved AS (
  SELECT c.eq AS machine, p.eq AS parent
    FROM clean c
    JOIN clean p         ON p.t = regexp_replace(c.t, '/[^/]+$', '')
    JOIN equipments em   ON em.id_equipment = c.eq AND em.tp_equipment = 1 AND em.id_enterprise = 3
    JOIN equipments ep   ON ep.id_equipment = p.eq AND ep.tp_equipment IN (2,3) AND ep.id_enterprise = 3
)
UPDATE equipments e
   SET id_parentequipment = r.parent
  FROM resolved r
 WHERE e.id_equipment = r.machine
   AND e.id_enterprise = 3
   AND e.id_parentequipment IS DISTINCT FROM r.parent;

-- Verify H3: expect null_machines = 0 (every tp=1 has a parent); 20 tp=3 roots stay NULL.
SELECT count(*) FILTER (WHERE tp_equipment = 1 AND id_parentequipment IS NULL) AS null_machines,
       count(*) FILTER (WHERE tp_equipment = 1 AND id_parentequipment IS NOT NULL) AS machines_with_parent,
       count(*) FILTER (WHERE tp_equipment IN (2,3) AND id_parentequipment IS NULL) AS roots_null_by_design
  FROM equipments
 WHERE id_enterprise = 3;

-- ---------------------------------------------------------------------------
-- H4 — Port client_descriptors from F1 (packiot) into F3 for CPACK (+ sandbox)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS dblink;

INSERT INTO public.client_descriptors
      (id_enterprise, tenant_code, descriptor, version, status,
       artifacts, validation, created_by, updated_by, created_at, updated_at)
SELECT f1.id_enterprise, f1.tenant_code, f1.descriptor, f1.version, f1.status,
       f1.artifacts, f1.validation, f1.created_by, f1.updated_by, f1.created_at, f1.updated_at
  FROM dblink(:'f1_dsn',
        $f1$ SELECT id_enterprise, tenant_code, descriptor, version, status,
                     artifacts, validation, created_by, updated_by, created_at, updated_at
                FROM public.client_descriptors
               WHERE id_enterprise IN (3, 2000003) $f1$)
    AS f1(id_enterprise integer, tenant_code text, descriptor jsonb, version integer,
          status text, artifacts jsonb, validation jsonb, created_by text, updated_by text,
          created_at timestamptz, updated_at timestamptz)
ON CONFLICT (id_enterprise) DO NOTHING;   -- non-destructive: never overwrite an edited F3 descriptor

-- Verify H4: expect a row for ent 3 (real CPACK descriptor, ~24KB) and ent 2000003.
SELECT id_enterprise, tenant_code, version, status,
       length(descriptor::text) AS descriptor_bytes
  FROM public.client_descriptors
 WHERE id_enterprise IN (3, 2000003)
 ORDER BY id_enterprise;

-- ---------------------------------------------------------------------------
-- H6a — Seed the pages dimension (from legacy prod packiot40; CPACK = legacy ent 1)
-- ---------------------------------------------------------------------------
-- Full 67-row page dimension materialized from legacy prod (it is empty on F1 and
-- lives nowhere in the repo). list_of_enterprises is REMAPPED to F3: the 12 pages
-- CPACK saw on legacy (legacy ent 1) => {3, 2000003}; every other tenant's custom
-- report => {} (their enterprises do not exist on this plane). page_info/id_page
-- are preserved verbatim so role desktop.screen[].code values still resolve.
-- Non-destructive: DO NOTHING keeps any enterprises later appended by
-- piot_insert_default_pages_to_new_enterprises().
INSERT INTO public.pages (id_page, list_of_enterprises, page_info, default_piot_page) VALUES
  (1, '{3,2000003}'::integer[], '{"URL": "/mission-control","name": "Mission Control","menu_group": 1}'::jsonb, true),
  (2, '{3,2000003}'::integer[], '{"URL": "/oee","name": "OEE","menu_group": 2,"page_order": 2}'::jsonb, true),
  (3, '{3,2000003}'::integer[], '{"URL": "/downtimes","name": "Downtimes","menu_group": 2,"page_order": 1}'::jsonb, true),
  (5, '{3,2000003}'::integer[], '{"URL": "/total-production","name": "Total Production","menu_group": 2,"page_order": 4}'::jsonb, true),
  (6, '{3,2000003}'::integer[], '{"URL": "/production-orders","name": "Production Orders","menu_group": 2,"page_order": 3}'::jsonb, true),
  (8, '{3,2000003}'::integer[], '{"URL": "/single-period","name": "Single Period","menu_group": 2,"page_order": 6}'::jsonb, true),
  (9, '{}'::integer[], '{"URL": "/production-flow","name": "Production Flow","menu_group": 2,"page_order": 5}'::jsonb, false),
  (10, '{}'::integer[], '{"URL": "/report","name": "Relatório PowerBI","hidden": false,"dataset": "084af97f-7da3-4700-b2f1-7373b6657f91","reportId": "511d7572-046b-4a47-a7f3-482f9374b252","menu_group": 4}'::jsonb, false),
  (11, '{}'::integer[], '{"URL": "/MissionControl35","name": "Mission Control Camargo","menu_group": 1}'::jsonb, false),
  (12, '{}'::integer[], '{"URL": "/report","name": "Albea Custom Report","dataset": "bfe9df8a-33c3-46a9-bab7-bd7ae7cc3983","reportId": "df396d0d-9552-43e0-8917-26c468bfcc18","menu_group": 4}'::jsonb, false),
  (13, '{}'::integer[], '{"URL": "/report","name": "01 - Prod. control Bruno","label": {"en-US": "01 - Prod. control Bruno","pt-BR": "01 - Controle Produção Bruno"},"dataset": "d7731c22-f3f0-4bbc-9473-5040fa9d33ed","reportId": "30293fc0-5663-4d0a-8e4d-daa902a0a3e6","menu_group": 4}'::jsonb, false),
  (14, '{}'::integer[], '{"URL": "/report","name": "01-Ausfälle-2021","label": {"en-US": "01-Ausfälle-2021 ","pt-BR": "01-Stops-2021"},"dataset": "532ea4a1-1034-48e5-94b9-60c28930fa0f","reportId": "95f8303d-fe7e-4476-8bcf-8ef512781697","menu_group": 4}'::jsonb, false),
  (15, '{}'::integer[], '{"URL": "/report","name": "02-Ausfälle-2022","label": {"en-US": "02-Ausfälle-2022 ","pt-BR": "02-Stops-2022"},"dataset": "7abd5fe9-f4e8-478e-ab1f-34a9cf643c31","reportId": "9293d691-39e2-4092-a586-97801eb666a4","menu_group": 4}'::jsonb, false),
  (16, '{}'::integer[], '{"URL": "/report","name": "03-Prod.Teams","dataset": "40212a9e-8657-461d-80a2-a8e62fc72728","reportId": "89b0eb65-c5ae-4835-815b-51cc7cff5969","menu_group": 4}'::jsonb, false),
  (17, '{}'::integer[], '{"URL": "/report","name": "Shift Report KY-FCL","dataset": "0819381c-4b97-4f5e-9a4e-c608b70256c4","reportId": "7cfad958-2f6e-46cd-9518-4366b75273e3","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 7}'::jsonb, false),
  (20, '{}'::integer[], '{"URL": "/report","name": "Incoplast Custom Report","dataset": "89366508-550e-417c-8449-f30a57034977","reportId": "40252f93-8047-4c24-b498-f52744a609b3","menu_group": 4}'::jsonb, false),
  (23, '{}'::integer[], '{"URL": "/report","name": "Incoplast Speed Analisys","dataset": "4c03497c-73b6-47b9-af3f-b8185354f8df","reportId": "f12ddaea-6e98-4ca4-aa6b-4086b694148a","menu_group": 4}'::jsonb, false),
  (24, '{3,2000003}'::integer[], '{"URL": "/settings","name": "Settings","menu_group": -1}'::jsonb, true),
  (25, '{3,2000003}'::integer[], '{"URL": "/home","name": "Home","menu_group": -1}'::jsonb, true),
  (26, '{3,2000003}'::integer[], '{"URL": "/scrap-period","name": "Scrap Period","menu_group": 2,"page_order": 7}'::jsonb, true),
  (27, '{3,2000003}'::integer[], '{"URL": "/machine-speed","name": "Machine Speed","menu_group": 2,"page_order": 8}'::jsonb, true),
  (28, '{}'::integer[], '{"URL": "/report","name": "Relatório Mobile","hidden": false,"dataset": "8484a662-2a92-44e1-9059-54fe2dedc7e5","reportId": "591ebaba-88be-4269-8c39-16eed763987b","menu_group": 4}'::jsonb, false),
  (29, '{}'::integer[], '{"URL": "/report","name": "Paradas Maiara","hidden": false,"dataset": "b54fd97f-cd8e-4b3c-bdeb-7eb8742918db","reportId": "f1954240-bf5d-4b9d-8581-1c1a83c45814","menu_group": 4}'::jsonb, false),
  (30, '{}'::integer[], '{"URL": "/report","name": "Shift Report HWK","dataset": "26d4f931-8f58-4346-9d3f-20ca6baabd67","reportId": "9f766223-d8bb-4e47-b358-8e1914fbaf9c","menu_group": 4,"page_order": 4}'::jsonb, false),
  (31, '{}'::integer[], '{"URL": "/report","name": "Shift Report KY-FTA","dataset": "064f1767-8f18-457c-ba14-84872b7918cb","reportId": "fcd4724b-3728-4614-b34f-332fe4cb9011","menu_group": 4,"page_order": 5}'::jsonb, false),
  (32, '{}'::integer[], '{"URL": "/report","name": "Teste CPack","hidden": false,"dataset": "b54fd97f-cd8e-4b3c-bdeb-7eb8742918db","reportId": "3d0b438a-0802-49d7-8674-35d7bde1e711","menu_group": 4}'::jsonb, false),
  (33, '{}'::integer[], '{"URL": "/report","name": "S.Report KY-FTA 12H","dataset": "f4d876b8-9f00-4e55-b815-7aefd0f33ba6","reportId": "d5ce26a7-1e45-492a-9d76-fb3e8c7f0018","menu_group": 4,"page_order": 6}'::jsonb, false),
  (34, '{}'::integer[], '{"URL": "/report","name": "04-CH-31days","label": {"en-US": "Total Production","pt-BR": "Prod Total Mes"},"dataset": "b87c315e-3ab1-4f3c-9f39-8991fa495132","reportId": "7869e8fb-534d-471a-b02c-92ace84ee8a4","menu_group": 4}'::jsonb, false),
  (35, '{}'::integer[], '{"URL": "/overviewsuzano","name": "Overview L1+L2","label": {"en-US": "Overview L1+L2","pt-BR": "Overview L1+L2"},"menu_group": 3}'::jsonb, false),
  (36, '{}'::integer[], '{"URL": "/report","name": "Shift Report MTL","dataset": "bb92ddc6-ac2a-40d8-b7e6-ee6943d81cfd","reportId": "d36353a9-e96c-45cf-914e-8deda79c18b9","menu_group": 4,"page_order": 3}'::jsonb, false),
  (37, '{}'::integer[], '{"URL": "/report","name": "Shift Report VA","dataset": "605995d0-6549-4b3c-92d8-ae312ec6b908","reportId": "0abfa7bd-c721-46cc-aed1-4d120d275549","menu_group": 4,"page_order": 1}'::jsonb, false),
  (38, '{}'::integer[], '{"URL": "/report","name": "05-HU-31days","label": {"en-US": "Total Production","pt-BR": "Prod Total Mes"},"dataset": "f75b11fe-d1c8-464f-a488-bc298938b7bd","reportId": "bdf024cd-460a-4dc0-b035-559bfff5a046","menu_group": 4}'::jsonb, false),
  (40, '{}'::integer[], '{"URL": "/report","name": "report_uns_day","dataset": "4fca10b8-e6f8-4f30-a46b-ddf8233be978","reportId": "fd6ec4f0-c067-4bc1-8666-00e9ed1ae070","menu_group": 4}'::jsonb, false),
  (41, '{}'::integer[], '{"URL": "/report","name": "S.Report VA 12H","dataset": "b90c5ed4-63a6-4a26-a582-8ad004925086","reportId": "7579b6df-a14a-4e58-8bf3-bc7d7c2e09a2","menu_group": 4,"page_order": 2}'::jsonb, false),
  (42, '{}'::integer[], '{"URL": "/report","name": "S.Report KY-FCL 12H","dataset": "ebf349a4-cb0d-4ce8-8941-88deb7bf16c8","reportId": "c411bf0a-45d5-409b-8d5e-f5998d434aaf","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 8}'::jsonb, false),
  (43, '{}'::integer[], '{"URL": "/report","name": "Shift Report","dataset": "b91db53f-7692-4b6e-9aa9-bbdcfdb8f7c6","reportId": "37e68bb5-3e9e-4a2e-960b-c0748e56f477","group_icon": "ri-file-copy-2-line","group_name": "ReportNEW","menu_group": 4,"page_order": 1}'::jsonb, false),
  (44, '{}'::integer[], '{"URL": "/report","name": "Produção","label": {"en-US": "Produção","pt-BR": "Produção"},"dataset": "0e882c2d-be2d-41f6-be7f-959d3217891f","reportId": "4ee99246-3950-4d06-b6de-9df1c0d31651","menu_group": 4}'::jsonb, false),
  (45, '{}'::integer[], '{"URL": "/report","name": "Paradas","label": {"en-US": "Paradas","pt-BR": "Paradas"},"dataset": "f2e008a0-22dc-40ad-8e8e-82636dfda3dd","reportId": "9c885a96-1f4e-4456-950b-86ff3f24d12d","menu_group": 4}'::jsonb, false),
  (46, '{}'::integer[], '{"URL": "/report","name": "Speed Report","dataset": "155b9758-876b-4700-b8af-2b876dcefd25","reportId": "7848e956-c327-488c-846c-ec5af7ba1f14","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 1}'::jsonb, false),
  (47, '{}'::integer[], '{"URL": "/report","name": "ALL Shift Report","dataset": "a641ea63-086d-4a65-a59d-10ddf34a1c61","reportId": "d2d67e75-4baf-4ca6-a6fe-c7c37443ae8d","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 9,"refresh_dataset": "*/20 * * * *"}'::jsonb, false),
  (48, '{}'::integer[], '{"URL": "/report","name": "Speed_Aug2023","dataset": "b91db53f-7692-4b6e-9aa9-bbdcfdb8f7c6","reportId": "40febf40-e015-4f83-96e0-ff1bc956a320","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 1}'::jsonb, false),
  (49, '{}'::integer[], '{"URL": "/report","name": "MTL Shift Report","dataset": "a641ea63-086d-4a65-a59d-10ddf34a1c61","reportId": "e18e202c-0ac0-499f-a8d3-08484dfb4b8c","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 10}'::jsonb, false),
  (50, '{}'::integer[], '{"URL": "/report","name": "HWK Shift Report","dataset": "a641ea63-086d-4a65-a59d-10ddf34a1c61","reportId": "eba2e2c6-ed5f-40c2-9d7f-81fa9a508664","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 11}'::jsonb, false),
  (51, '{}'::integer[], '{"URL": "/report","name": "KY Shift Report","dataset": "a641ea63-086d-4a65-a59d-10ddf34a1c61","reportId": "9a762e91-7203-4388-8252-57183026b135","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 12}'::jsonb, false),
  (52, '{}'::integer[], '{"URL": "/report","name": "VA Shift Report","dataset": "a641ea63-086d-4a65-a59d-10ddf34a1c61","reportId": "db0172f0-34eb-44ae-9bc6-f6f9b51eb379","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 13}'::jsonb, false),
  (53, '{}'::integer[], '{"URL": "/report","name": "Prod Report","dataset": "24a25cf7-6ea2-44f7-ac11-0dc1c8bc9299","reportId": "28865801-2876-417e-81bd-2960e9067049","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 14}'::jsonb, false),
  (54, '{}'::integer[], '{"URL": "/report","name": "Shift Report","dataset": "b91db53f-7692-4b6e-9aa9-bbdcfdb8f7c6","reportId": "37e68bb5-3e9e-4a2e-960b-c0748e56f477","group_icon": "ri-file-copy-2-line","group_name": "ReportNEW","menu_group": 4,"page_order": 1}'::jsonb, false),
  (55, '{}'::integer[], '{"URL": "/report","name": "Setup Analysis","dataset": "717992fe-5443-4d47-b30e-97ef4baeb457","reportId": "adae5f0c-30d7-466f-ace8-2a783f3f8b99","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 15}'::jsonb, false),
  (56, '{}'::integer[], '{"URL": "/report","name": "Speed Flexo","dataset": "922cb5fd-d00a-4402-903f-5c2b7c6af689","reportId": "c5ac69a0-bf0c-4bd5-be2d-ac1f127708d1","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 1}'::jsonb, false),
  (57, '{}'::integer[], '{"URL": "/report","name": "List of Stops","dataset": "9a40f886-57f7-4c13-af6b-98a5f774bd99","reportId": "d1f6d9e4-5cf3-4ae7-b96c-6fb5191ed41b","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 3}'::jsonb, false),
  (58, '{}'::integer[], '{"URL": "/report","name": "Relat. Consumo Turno","dataset": "ae051091-9c1d-430e-a06a-43b41937646e","reportId": "1e7a149a-2f36-4be1-9ed5-386b3135e44d","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 1}'::jsonb, false),
  (59, '{}'::integer[], '{"URL": "/report","name": "Report CAMARGO","dataset": "c820f954-d5e9-4ad8-9171-fe37136232ee","reportId": "989cc162-920b-4106-b447-7fd92397623d","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 1}'::jsonb, false),
  (60, '{}'::integer[], '{"URL": "/report","name": "Report A4 test","dataset": "cf6c9054-e89a-4996-bf1a-9e02957c74ff","reportId": "65a11a26-8bfb-41c5-b9b1-c18e642976c7","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 5}'::jsonb, false),
  (61, '{}'::integer[], '{"URL": "/report","name": "Shift Report","dataset": "b91db53f-7692-4b6e-9aa9-bbdcfdb8f7c6","reportId": "37e68bb5-3e9e-4a2e-960b-c0748e56f477","group_icon": "ri-file-copy-2-line","group_name": "ReportNEW","menu_group": 4,"page_order": 1,"refresh_dataset": "18 * * * *"}'::jsonb, false),
  (62, '{}'::integer[], '{"URL": "/report","name": "Relatório OEE","label": {"en-US": "Relatorio OEE","pt-BR": "Relatorio OEE"},"dataset": "e3812a2a-fdd4-42d8-a4bc-00678cb338d1","reportId": "4a6aaf6f-3b12-448e-8b6e-3023e2fe606d","menu_group": 4}'::jsonb, false),
  (63, '{}'::integer[], '{"URL": "/report","name": "Relatório Paradas","label": {"en-US": "Relatorio Downtime","pt-BR": "Relatorio Downtime"},"dataset": "94395a06-1948-447c-96e7-d8fd7e5df213","reportId": "9c02bf5e-e817-4fe8-9471-f95c8de342ae","menu_group": 4}'::jsonb, false),
  (64, '{3,2000003}'::integer[], '{"URL": "/report","name": "Paradas C-Pack","dataset": "15580032-69cf-4f11-8d4c-78968868b616","reportId": "72d438d6-fe4f-4e3b-b69b-c50631ee9f46","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 15}'::jsonb, false),
  (66, '{}'::integer[], '{"URL": "/report","name": "06-HU-SAP","label": {"en-US": "SAP Neopac HU","pt-BR": "SAP Neopac HU"},"dataset": "6a97b97b-8cfa-4c26-9246-150cfd1d1580","reportId": "1d7174b7-6f55-4a22-b5ff-253b51c2b531","menu_group": 4}'::jsonb, false),
  (67, '{}'::integer[], '{"URL": "/report","name": "Bobinas","dataset": "d8bb52a6-bee0-48a3-ba18-31934e453e25","reportId": "6c550f80-a70b-4d19-b5d7-234b17f250bd","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 1}'::jsonb, false),
  (68, '{}'::integer[], '{"URL": "/report","name": "07-Sensors-OBD","label": {"en-US": "Sensors OBD","pt-BR": "Sensor OBD"},"dataset": "61b9947c-d828-4f6a-b61c-9b4c41706b86","reportId": "b735cd78-a9cb-40b8-96c6-ef3d4e0204e1","menu_group": 4,"refresh_dataset": "41 * * * *"}'::jsonb, false),
  (69, '{}'::integer[], '{"URL": "/report","name": "08-Sensors-DEB","label": {"en-US": "Sensors-DEB","pt-BR": "Sensors-DEB"},"dataset": "9f3ed2e5-93b9-4ffa-961a-c0f3f0ce6d96","reportId": "fc61c82e-e08e-4469-969b-b5b30c43f869","menu_group": 4,"refresh_dataset": "51 * * * *"}'::jsonb, false),
  (70, '{}'::integer[], '{"URL": "/report","name": "09-Mobile-ODB","label": {"en-US": "Mobile-ODB","pt-BR": "Mobile-ODB"},"dataset": "ae748334-f627-498b-a417-6e41ff701d5d","reportId": "5687d7a2-b135-4ed9-b654-c96cda923da2","menu_group": 4}'::jsonb, false),
  (72, '{}'::integer[], '{"URL": "/report","name": "10-Sensors-WIL","label": {"en-US": "Sensors-WIL","pt-BR": "Sensors-WIL"},"dataset": "9ddf97be-c6da-4c90-9908-05d266b9efe1","reportId": "2bfad1b6-e34e-4153-a688-90d15f90cc49","menu_group": 4}'::jsonb, false),
  (73, '{}'::integer[], '{"URL": "/report","name": "DataSync Analysis","dataset": "3a14b0a6-3fda-47ea-95a4-7aa2c363abeb","reportId": "f604d004-77bc-4bd1-a2e0-872782a563a6","group_icon": "ri-file-copy-2-line","group_name": "Custom Report","menu_group": 4,"page_order": 16}'::jsonb, false),
  (74, '{}'::integer[], '{"URL": "/report","name": "11-SAP-CH-API","label": {"en-US": "SAP-CH-API","pt-BR": "SAP-CH-API"},"dataset": "0195f718-5452-4d99-b45f-5f1cb1ae8657","reportId": "ebc3a761-ab12-4d1c-831a-5fb5bc011764","menu_group": 4}'::jsonb, false),
  (75, '{}'::integer[], '{"URL": "/report","name": "Prod_Stops_OPs","label": {"en-US": "Prod_Stops_OPs","pt-BR": "Prod_Stops_OPs"},"dataset": "b15e268b-31c4-4a0d-829c-2981b41c0612","reportId": "ee56ad66-c0e3-4165-bc42-0db1d6f65a37","menu_group": 4}'::jsonb, false),
  (76, '{3,2000003}'::integer[], '{"URL": "/report","name": "Relatorio Sensores","label": {"en-US": "Relatorio Sensores","pt-BR": "Relatorio Sensores"},"dataset": "8705e4cc-bd98-4314-9955-9b94c60e83b2","reportId": "a662e67b-209d-4d73-97d4-00bca40011d2","menu_group": 4}'::jsonb, false)
ON CONFLICT (id_page) DO NOTHING;

-- ---------------------------------------------------------------------------
-- H6b — Populate the operator role's desktop.screen (+ line) entitlements
-- ---------------------------------------------------------------------------
-- desktop.screen = CPACK's authentic non-super screen set (legacy "Supervisor"
-- role 247, all read-only). desktop.line = every top-level line/cell (tp=3) of the
-- enterprise, so the per-equipment Overview branch of v_menu_per_user_role also
-- populates. Applied to both the CPACK role (ent 3) and its sandbox twin (2000003).
WITH role_lines AS (
  SELECT id_enterprise, jsonb_agg(id_equipment ORDER BY id_equipment) AS lines
    FROM equipments
   WHERE tp_equipment = 3
     AND id_enterprise IN (3, 2000003)
   GROUP BY id_enterprise
),
target AS (
  SELECT rl.id_enterprise,
         jsonb_build_object('desktop', jsonb_build_object(
           'line', rl.lines,
           'screen', '[{"code": -1, "write": false}, {"code": 1, "write": false},
                       {"code": 2, "write": false}, {"code": 3, "write": false},
                       {"code": 5, "write": false}, {"code": 6, "write": false},
                       {"code": 8, "write": false}, {"code": 25, "write": false},
                       {"code": 26, "write": false}, {"code": 27, "write": false},
                       {"code": 64, "write": false}]'::jsonb)) AS perms
    FROM role_lines rl
)
UPDATE public.user_roles ur
   SET permissions = t.perms
  FROM target t
 WHERE ur.id_enterprise = t.id_enterprise
   AND ur.nm_user_role = 'operator-cpack-staging'
   AND ur.permissions IS DISTINCT FROM t.perms;

-- Verify H6: expect >= 1 menu row for ent 3 / role 3 (and 2000003), with menu groups.
-- (menu is a jsonb[] array column -> array_length, not jsonb_array_length.)
SELECT id_enterprise, id_user_role, array_length(menu, 1) AS menu_groups
  FROM v_menu_per_user_role
 WHERE id_enterprise IN (3, 2000003)
 ORDER BY id_enterprise;

COMMIT;
