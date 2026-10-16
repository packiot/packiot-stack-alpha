-- Ideal speeds that were clearly off (2026-09-29, user-approved).
-- Rule for "clearly off": > 25% of sustained production hours (running >= 50 min,
-- last 30 days) beat the configured ideal by > 5%. A correct ideal is a ceiling
-- that is rarely beaten; performance above 100% most of the time means the
-- configured value is too low. New value = best demonstrated rate = p95 of the
-- sustained hourly infeed rate (gross / running minute), rounded.
--   ent5 L60  lead M682     (2000350) 110 -> 241  (99.2% of 266 hours over)
--   ent5 L90  lead S2OUTPUT (2000330)  60 ->  79  (34.1% of 164 hours over)
--   ent3 ISIMAT              (90)       70 ->  85  (72.3% of 119 hours over)
--   ent3 SLEEVE1             (107)      90 -> 101  (33.0% of 297 hours over)
-- NOT changed (see PR): HOTMADAG (3 products run ~3x faster: needs per-product
-- speeds), L01 (a 09-14..15 counting episode, not a config error), L8/CER400
-- (under the threshold). The line-lead pass reads the LEAD machine's speed.
-- Bispharma production targets were seeded as 85% x speed (PR #1381) and still
-- equal that formula, so they are re-derived the same way:
--   vl_hour = round(speed*60*0.85), shift x8, day x24, week x7 days, month x30 days.
BEGIN;
UPDATE core.equipments SET production_speed = 241 WHERE id_equipment = 2000350 AND production_speed = 110;
UPDATE core.equipments SET production_speed =  79 WHERE id_equipment = 2000330 AND production_speed =  60;
UPDATE core.equipments SET production_speed =  85 WHERE id_equipment =      90 AND production_speed =  70;
UPDATE core.equipments SET production_speed = 101 WHERE id_equipment =     107 AND production_speed =  90;
UPDATE config.production_targets SET vl_hour = 12291, vl_shift = 98328, vl_day = 294984, vl_week = 2064888, vl_month = 8849520
 WHERE id_equipment = 2000349 AND vl_hour = 5610;
UPDATE config.production_targets SET vl_hour = 4029, vl_shift = 32232, vl_day = 96696, vl_week = 676872, vl_month = 2900880
 WHERE id_equipment = 2000328 AND vl_hour = 3060;
SELECT 'speeds', id_equipment, production_speed FROM core.equipments WHERE id_equipment IN (2000350, 2000330, 90, 107) ORDER BY 2;
SELECT 'targets', id_equipment, vl_hour, vl_shift FROM config.production_targets WHERE id_equipment IN (2000349, 2000328) ORDER BY 2;
COMMIT;
