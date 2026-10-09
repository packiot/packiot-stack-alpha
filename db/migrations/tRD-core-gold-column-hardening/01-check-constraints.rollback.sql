-- Rollback for tRD-core-gold-column-hardening/01-check-constraints.up.sql
SET lock_timeout = '5s';
ALTER TABLE gold.area_oee_daily              DROP CONSTRAINT IF EXISTS area_oee_daily_oee_bounds;
ALTER TABLE gold.equipment_oee_monthly       DROP CONSTRAINT IF EXISTS equipment_oee_monthly_oee_bounds;
ALTER TABLE gold.equipment_oee_shift_weekly  DROP CONSTRAINT IF EXISTS equipment_oee_shift_weekly_oee_bounds;
ALTER TABLE gold.equipment_oee_shift_monthly DROP CONSTRAINT IF EXISTS equipment_oee_shift_monthly_oee_bounds;
ALTER TABLE core.production_orders           DROP CONSTRAINT IF EXISTS production_orders_status_domain;
ALTER TABLE core.equipments                  DROP CONSTRAINT IF EXISTS equipments_tp_equipment_domain;
ALTER TABLE core.equipments                  DROP CONSTRAINT IF EXISTS equipments_net_production_type_domain;
ALTER TABLE core.enterprises                 DROP CONSTRAINT IF EXISTS enterprises_scrap_calc_type_domain;
