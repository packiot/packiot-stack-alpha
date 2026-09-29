BEGIN;
UPDATE core.equipments SET production_speed = 110 WHERE id_equipment = 2000350;
UPDATE core.equipments SET production_speed =  60 WHERE id_equipment = 2000330;
UPDATE core.equipments SET production_speed =  70 WHERE id_equipment =      90;
UPDATE core.equipments SET production_speed =  90 WHERE id_equipment =     107;
UPDATE config.production_targets SET vl_hour = 5610, vl_shift = 44880, vl_day = 134640, vl_week = 942480, vl_month = 4039200 WHERE id_equipment = 2000349;
UPDATE config.production_targets SET vl_hour = 3060, vl_shift = 24480, vl_day = 73440, vl_week = 514080, vl_month = 2203200 WHERE id_equipment = 2000328;
COMMIT;
