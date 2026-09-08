-- Rollback for task #221 — restore the FLAT 1-min serving.machine_speed view.
-- (Reverses 01_serving_machine_speed_fn.up.sql. Legacy public.h_piot_machine_speed
--  is never touched by the up migration, so no restore is needed for it.)
DROP FUNCTION IF EXISTS serving.machine_speed(integer,text,text,text,text,text,timestamptz,timestamptz,text,text);

CREATE OR REPLACE VIEW serving.machine_speed AS
 SELECT eq.id_enterprise,
    m.id_equipment,
    eq.nm_equipment,
    m.bucket AS ts_value,
    m.sum_speed / NULLIF(m.cnt_speed, 0)::double precision AS speed,
    m.max_speed AS plc_speed_max,
    eq.production_speed AS ideal_production_speed,
    m.sum_gross,
    m.sum_net,
    m.sum_scrap,
    m.cnt_rows,
    m.tp_equipment,
    eq.nm_equipment::text ||
        CASE eq.tp_equipment
            WHEN 3 THEN ' (line)'::text
            WHEN 1 THEN ' (machine)'::text
            WHEN 2 THEN ' (sector)'::text
            ELSE ''::text
        END AS equipment_label
   FROM silver.equipment_metrics_1min m
     JOIN equipments eq ON eq.id_equipment = m.id_equipment;
