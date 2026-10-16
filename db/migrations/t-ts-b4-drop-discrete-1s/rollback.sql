-- rollback for t-ts-b4-drop-discrete-1s — recreate silver.ca_discrete_changes_1s exactly as it was on
-- staging 2026-10-15: definition (materialized_only=false), owner, grants, comments, compression
-- (segmentby id_equipment, orderby ts_value DESC) after 7 d, refresh 30 min / 1 min every 15 min,
-- retention 90 d, catalog row. It comes back empty and materializes from the refresh policy; the
-- deriver no longer reads it (#1807), so nothing waits on it.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE MATERIALIZED VIEW IF NOT EXISTS silver.ca_discrete_changes_1s
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
 SELECT time_bucket('00:00:01'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_equipment, equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area,
    equipment_values.state, equipment_values.mode, equipment_values.id_order, equipment_values.id_production_order,
    equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.ts_value_production,
    equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.sub_mode,
    equipment_values.ideal_production_speed
   FROM silver.equipment_values
  WHERE NOT (equipment_values.state IS NULL AND equipment_values.mode IS NULL AND equipment_values.id_order IS NULL
         AND equipment_values.id_production_order IS NULL AND equipment_values.conversion_factor IS NULL
         AND equipment_values.number_cavities IS NULL AND equipment_values.ts_value_production IS NULL
         AND equipment_values.id_shift IS NULL AND equipment_values.id_team IS NULL AND equipment_values.id_shift_hour IS NULL
         AND equipment_values.sub_mode IS NULL AND equipment_values.ideal_production_speed IS NULL)
  GROUP BY (time_bucket('00:00:01'::interval, equipment_values.ts_value)), equipment_values.id_equipment,
    equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.state,
    equipment_values.mode, equipment_values.id_order, equipment_values.id_production_order, equipment_values.conversion_factor,
    equipment_values.number_cavities, equipment_values.ts_value_production, equipment_values.id_shift, equipment_values.id_team,
    equipment_values.id_shift_hour, equipment_values.sub_mode, equipment_values.ideal_production_speed
WITH NO DATA;

ALTER MATERIALIZED VIEW silver.ca_discrete_changes_1s OWNER TO postgres;
GRANT SELECT ON silver.ca_discrete_changes_1s TO cloudbeaver_ro, readapi_ro, stream_engine;
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.ca_discrete_changes_1s TO cloudbeaver_rw;

COMMENT ON VIEW silver.ca_discrete_changes_1s IS 'SILVER CONTINUOUS AGGREGATE (1-second bucket over silver.equipment_values). Discrete state/mode/order change grain feeding the CPAC downtime deriver — captures per-second categorical values used to detect transitions.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.ts_value IS 'Start of the 1-second time bucket (tz-aware).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.state IS 'PackML state for the second (aggregated).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.mode IS 'PackML mode for the second (aggregated).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_order IS 'Client-facing production order code for the second (string).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_production_order IS 'FK core.production_orders for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.conversion_factor IS 'Conversion factor for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.number_cavities IS 'Cavity count for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.ts_value_production IS 'Production/business date for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_shift IS 'FK core.shifts for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_team IS 'Team id for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_shift_hour IS 'FK core.shift_hours for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.sub_mode IS 'PackML sub-mode string for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.ideal_production_speed IS 'Ideal/nominal production speed for the second (units/time).';

ALTER MATERIALIZED VIEW silver.ca_discrete_changes_1s SET (timescaledb.compress = true,
  timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_value DESC');
SELECT add_continuous_aggregate_policy('silver.ca_discrete_changes_1s', start_offset => INTERVAL '30 minutes',
       end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '15 minutes', if_not_exists => true);
SELECT add_compression_policy('silver.ca_discrete_changes_1s', compress_after => INTERVAL '7 days', if_not_exists => true);
SELECT add_retention_policy('silver.ca_discrete_changes_1s', drop_after => INTERVAL '90 days', if_not_exists => true);
INSERT INTO ops.retention_policy (relation, kind, time_expr, keep, tier, purge_order, cold_copy, rationale)
VALUES ('silver.ca_discrete_changes_1s', 'cagg', 'ts_value', '90 days', 'hot_raw', 100, NULL, '1 s cagg; 2.5 GB/90 d. Derivable from raw.')
ON CONFLICT (relation) DO NOTHING;
COMMIT;
