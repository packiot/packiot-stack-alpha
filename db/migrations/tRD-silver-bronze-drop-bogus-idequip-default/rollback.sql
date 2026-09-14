-- Rollback: restore the (bogus) sequence default exactly as it was.
ALTER TABLE silver.equipment_values
    ALTER COLUMN id_equipment SET DEFAULT nextval('silver.equipment_values_id_equipment_seq'::regclass);
ALTER TABLE bronze.equipment_values_raw
    ALTER COLUMN id_equipment SET DEFAULT nextval('silver.equipment_values_id_equipment_seq'::regclass);
