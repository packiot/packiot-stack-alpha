-- t-i18n-availability-states — front4 labels for the availability three-state policy (2026-10-01)
-- New keys (front4 #294 used English fallbacks). `status_no_data` is separate from the
-- existing `no_data`, which is the empty-state SENTENCE ("Sem dados no momento!") and
-- reads wrong as a status label. ON CONFLICT DO NOTHING: never overwrite a human edit.
BEGIN;
INSERT INTO config.translations (language_tag, app, namespace, key, value, updated_at, updated_by)
SELECT t.lang, 'front4', 'common', t.key, t.value, now(), 't-i18n-availability-states'
  FROM (VALUES
    ('en-US', 'status_no_data', 'No data'),
    ('pt-BR', 'status_no_data', 'Sem dados'),
    ('de-DE', 'status_no_data', 'Keine Daten'),
    ('hu-HU', 'status_no_data', 'Nincs adat'),
    ('pl-PL', 'status_no_data', 'Brak danych'),
    ('en-US', 'out_of_service', 'Out of service'),
    ('pt-BR', 'out_of_service', 'Fora de operação'),
    ('de-DE', 'out_of_service', 'Außer Betrieb'),
    ('hu-HU', 'out_of_service', 'Üzemen kívül'),
    ('pl-PL', 'out_of_service', 'Poza eksploatacją'),
    ('en-US', 'data_coverage', 'Data coverage'),
    ('pt-BR', 'data_coverage', 'Cobertura de dados'),
    ('de-DE', 'data_coverage', 'Datenabdeckung'),
    ('hu-HU', 'data_coverage', 'Adatlefedettség'),
    ('pl-PL', 'data_coverage', 'Pokrycie danymi'),
    ('en-US', 'not_counted', 'not counted'),
    ('pt-BR', 'not_counted', 'não contabilizado'),
    ('de-DE', 'not_counted', 'nicht gezählt'),
    ('hu-HU', 'not_counted', 'nem számít bele'),
    ('pl-PL', 'not_counted', 'nie wliczane')
  ) AS t(lang, key, value)
ON CONFLICT DO NOTHING;
COMMIT;
