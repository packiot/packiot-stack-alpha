BEGIN;
DELETE FROM config.translations
 WHERE app = 'front4' AND namespace = 'common' AND updated_by = 't-i18n-availability-states'
   AND key IN ('status_no_data', 'out_of_service', 'data_coverage', 'not_counted');
COMMIT;
