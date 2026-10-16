-- t-sap-report-page rollback — removes the /sap-report grant, page row and the i18n keys this migration added.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $sap$
DECLARE v_page integer;
BEGIN
  SELECT id_page INTO v_page FROM config.pages WHERE page_info->>'URL' = '/sap-report' LIMIT 1;
  IF v_page IS NULL THEN
    RAISE NOTICE 't-sap-report-page rollback: no /sap-report page — nothing to undo';
    RETURN;
  END IF;
  UPDATE identity.user_roles ur
     SET permissions = jsonb_set(ur.permissions, '{desktop,screen}',
           coalesce((SELECT jsonb_agg(s ORDER BY o)
                       FROM jsonb_array_elements(ur.permissions->'desktop'->'screen') WITH ORDINALITY e(s, o)
                      WHERE s->>'code' IS DISTINCT FROM v_page::text), '[]'::jsonb))
   WHERE jsonb_typeof(ur.permissions->'desktop'->'screen') = 'array'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(ur.permissions->'desktop'->'screen') s
                  WHERE s->>'code' = v_page::text);
  DELETE FROM config.pages WHERE id_page = v_page;
END
$sap$;

DELETE FROM config.translations
 WHERE app = 'front4' AND namespace = 'common' AND updated_by = 't-sap-report-page';

COMMIT;
