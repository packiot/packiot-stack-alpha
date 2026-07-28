-- packml_register rows for tenant BISPHARMA (enterprise 7) — generated from the
-- client descriptor (ADR-0045 P1). DO NOT hand-edit; edit the descriptor + regenerate.
INSERT INTO packml_register (id_enterprise, id_equipment, packml_topic, active, id_unit)
VALUES
    (7, 700, 'BISPHARMA/SP/BLISTER1', true, NULL),
    (7, 701, 'BISPHARMA/SP/BLISTER1/UHLMANN', true, 701),
    (7, 702, 'BISPHARMA/SP/CARTONER1', true, NULL),
    (7, 703, 'BISPHARMA/SP/CARTONER1/MARCHESINI', true, 703)
ON CONFLICT (packml_topic) DO NOTHING;
