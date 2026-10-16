SELECT count(*) AS tables_with_columns FROM information_schema.columns
 WHERE table_schema = 'gold' AND column_name IN ('no_data_time', 'out_of_service_time');   -- expect 16
SELECT id_enterprise, id_equipment, period, reason FROM config.equipment_out_of_service ORDER BY 1, 2;
