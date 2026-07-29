-- packml_register rows for tenant BISNAGO (enterprise 119) — generated from the
-- client descriptor (ADR-0045 P1). DO NOT hand-edit; edit the descriptor + regenerate.
INSERT INTO packml_register (id_enterprise, id_equipment, packml_topic, active, id_unit)
VALUES
    (119, 41001, 'BISNAGO/SP/LINHAS/L71', true, NULL),
    (119, 41101, 'BISNAGO/SP/LINHAS/L71/M670', true, 41101),
    (119, 41102, 'BISNAGO/SP/LINHAS/L71/M671', true, 41102),
    (119, 41002, 'BISNAGO/SP/LINHAS/L72', true, NULL),
    (119, 41103, 'BISNAGO/SP/LINHAS/L72/M672', true, 41103),
    (119, 41104, 'BISNAGO/SP/LINHAS/L72/M673', true, 41104),
    (119, 41003, 'BISNAGO/SP/LINHAS/L73', true, NULL),
    (119, 41105, 'BISNAGO/SP/LINHAS/L73/M674', true, 41105),
    (119, 41106, 'BISNAGO/SP/LINHAS/L73/M675', true, 41106),
    (119, 41004, 'BISNAGO/SP/LINHAS/L56', true, NULL),
    (119, 41107, 'BISNAGO/SP/LINHAS/L56/M676', true, 41107),
    (119, 41108, 'BISNAGO/SP/LINHAS/L56/M677', true, 41108),
    (119, 41005, 'BISNAGO/SP/LINHAS/L57', true, NULL),
    (119, 41109, 'BISNAGO/SP/LINHAS/L57/M678', true, 41109),
    (119, 41110, 'BISNAGO/SP/LINHAS/L57/M679', true, 41110),
    (119, 41006, 'BISNAGO/SP/LINHAS/L58', true, NULL),
    (119, 41111, 'BISNAGO/SP/LINHAS/L58/M680', true, 41111),
    (119, 41112, 'BISNAGO/SP/LINHAS/L58/M681', true, 41112),
    (119, 41007, 'BISNAGO/SP/LINHAS/L60', true, NULL),
    (119, 41113, 'BISNAGO/SP/LINHAS/L60/M682', true, 41113),
    (119, 41114, 'BISNAGO/SP/LINHAS/L60/M683', true, 41114)
ON CONFLICT (packml_topic) DO NOTHING;
