-- t-equipment-values-speed-idx — partial index for "latest row with a speed" per equipment
--
-- stream-engine's live-status job (uns/current_metrics.go, every minute) looks up each
-- equipment's latest row with state, with speed, and any row over the last 7 days.
-- "state" has a partial index (equipment_values_id_equipment_ts_value_state_idx) and
-- runs in 23 ms; "speed" had none, so for machines that rarely report speed the probe
-- walked all 7 days of rows: 1.6 s of the job's ~2.7 s (and a 13 s mean under load,
-- ~10 pct of analytics DB time). Same shape as the state index.
--
-- Hypertables can't CREATE INDEX CONCURRENTLY; transaction_per_chunk builds each chunk
-- in its own short transaction (brief write lock on that chunk only; compressed chunks
-- are skipped). Must run OUTSIDE a transaction block. Idempotent.
SET lock_timeout = '30s';
CREATE INDEX IF NOT EXISTS equipment_values_id_equipment_ts_value_speed_idx
    ON silver.equipment_values (id_equipment, ts_value DESC, speed)
  WITH (timescaledb.transaction_per_chunk)
 WHERE speed IS NOT NULL;
