-- Expect: the column exists; exactly Bispharma L90 is false.
SELECT id_enterprise, nm_equipment, fill_missing_meter
  FROM core.equipments WHERE fill_missing_meter IS NOT NULL ORDER BY 1, 2;
