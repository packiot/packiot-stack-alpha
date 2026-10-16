-- verify for t-adr0065-p4-hot-windows. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 windows: bronze 14/14, silver values 35, plc link 35: 14 days|14 days|35 days|35 days',
       (SELECT keep FROM ops.retention_policy WHERE relation = 'bronze.equipment_values_raw'),
       (SELECT keep FROM ops.retention_policy WHERE relation = 'bronze.equipment_events_raw'),
       (SELECT keep FROM ops.retention_policy WHERE relation = 'silver.equipment_values'),
       (SELECT keep FROM ops.retention_policy WHERE relation = 'silver.plc_link_minutes');
SELECT 'V2 silver.equipment_values still gated by a cold copy: t',
       (SELECT nullif(cold_copy, 'none') IS NOT NULL FROM ops.retention_policy WHERE relation = 'silver.equipment_values');
SELECT 'V3 unchanged: events 5 y, minute fact 90 d: 5 years|90 days',
       (SELECT keep FROM ops.retention_policy WHERE relation = 'silver.equipment_events'),
       (SELECT keep FROM ops.retention_policy WHERE relation = 'silver.equipment_categorical_1min');
SELECT 'I1 partitions the gate is holding back (informational)', count(*) FROM ops.partition_drop_blocked;
