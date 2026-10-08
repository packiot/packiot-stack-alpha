-- t-sap-report-page verify — read-only. Run after 01-up.sql on the analytics DB.
-- Expect:
--   1. exactly one /sap-report page, menu_group 4, list_of_enterprises = the sap_de tenants
--   2. every role holding the page code is in a sap_de tenant (no cross-tenant grant)
--   3. each grantee role now renders the page in serving.v_menu_per_user_role
--   4. 22 i18n keys × 5 languages present (110 rows, some may pre-exist from a human edit)
--   5. no role lost a pre-existing screen grant (count of code-66 holders == count of grantees,
--      unless CS granted the page manually afterwards)
\set ON_ERROR_STOP 1
BEGIN READ ONLY;

SELECT id_page, page_info->>'URL' AS url, (page_info->>'menu_group')::int AS menu_group, list_of_enterprises,
       ARRAY(SELECT cd.id_enterprise FROM core.client_descriptors cd
              WHERE serving.report_config(cd.id_enterprise)->>'family' = 'sap_de' ORDER BY 1) AS sap_de_tenants
  FROM config.pages WHERE page_info->>'URL' = '/sap-report';

WITH p AS (SELECT id_page FROM config.pages WHERE page_info->>'URL' = '/sap-report')
SELECT ur.id_enterprise, ur.id_user_role, ur.nm_user_role,
       serving.report_config(ur.id_enterprise)->>'family' = 'sap_de' AS tenant_is_sap,   -- expect all true
       EXISTS (SELECT 1 FROM jsonb_array_elements(ur.permissions->'desktop'->'screen') s WHERE s->>'code' = '66') AS had_legacy_66
  FROM identity.user_roles ur, p
 WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(ur.permissions->'desktop'->'screen') s WHERE s->>'code' = p.id_page::text)
 ORDER BY 1, 2;

SELECT m.id_enterprise, m.id_user_role,
       EXISTS (SELECT 1 FROM unnest(m.menu) g, jsonb_array_elements(g->'menu_items') i
                WHERE i->>'URL' = '/sap-report') AS menu_has_sap_report               -- expect true per grantee
  FROM v_menu_per_user_role m
 WHERE m.id_enterprise IN (SELECT cd.id_enterprise FROM core.client_descriptors cd
                            WHERE serving.report_config(cd.id_enterprise)->>'family' = 'sap_de')
 ORDER BY 1, 2;

SELECT language_tag, count(*) AS keys
  FROM config.translations
 WHERE app = 'front4' AND namespace = 'common'
   AND (key LIKE 'sap\_%' OR key = 'export_csv')
 GROUP BY 1 ORDER BY 1;                                                                     -- expect 22 each

ROLLBACK;
