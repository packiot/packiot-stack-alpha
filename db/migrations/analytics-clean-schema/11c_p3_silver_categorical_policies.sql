-- P3 — refresh policies on EVERY categorical tier (the #196/#206 lesson) + assertion.
SELECT add_continuous_aggregate_policy('silver.equipment_categorical_1min',
    start_offset => INTERVAL '3 hours',  end_offset => INTERVAL '2 minutes',  schedule_interval => INTERVAL '2 minutes');
SELECT add_continuous_aggregate_policy('silver.equipment_categorical_10min',
    start_offset => INTERVAL '6 hours',  end_offset => INTERVAL '10 minutes', schedule_interval => INTERVAL '10 minutes');
SELECT add_continuous_aggregate_policy('silver.equipment_categorical_1hour',
    start_offset => INTERVAL '1 day',    end_offset => INTERVAL '1 hour',     schedule_interval => INTERVAL '30 minutes');

-- Assertion: all 3 categorical tiers must have a refresh policy (fail loud otherwise).
-- Refresh-policy jobs carry the mat-hypertable id in config->>'mat_hypertable_id';
-- map it back to the silver categorical caggs via the TS catalog.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n
    FROM timescaledb_information.jobs j
    WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
      AND (j.config->>'mat_hypertable_id')::int IN (
        SELECT ca.mat_hypertable_id
        FROM _timescaledb_catalog.continuous_agg ca
        JOIN _timescaledb_catalog.hypertable h ON h.id = ca.mat_hypertable_id
        WHERE ca.user_view_schema='silver' AND ca.user_view_name LIKE 'equipment_categorical_%');
    IF n <> 3 THEN
        RAISE EXCEPTION 'categorical refresh-policy assertion failed: expected 3, got %', n;
    END IF;
    RAISE NOTICE 'categorical refresh-policy assertion OK: 3/3 tiers policied';
END $$;
