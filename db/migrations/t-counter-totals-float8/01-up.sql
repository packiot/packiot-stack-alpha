-- t-counter-totals-float8 — exact running counter totals (double precision) next to the float4 *_val columns.
--
-- WHY: silver.equipment_values / bronze.equipment_values_raw store the running counter totals (*_val) as real (float4),
-- which is integer-exact only up to 2^24 = 16,777,216. The largest client's totals reach 2.98e8 (gross) / 2.72e8 (net),
-- where float4 keeps only every 32nd integer: each stored total can be off by up to ±16 (602,864 gross / 381,205 net rows
-- above 2^24 in the 30 days before 2026-10-07; read-only probe). Increments (*_incr) are computed upstream in float64 and
-- stay < 2^24, so they are exact; the damage is (1) stream-engine re-seeds its increment clamp from the stored, rounded total
-- after every restart (writers/totalizer_seed.go), and (2) invariants comparing counter movement with summed increments.
--
-- MODEL: forward-only. ALTER COLUMN TYPE is impossible on hypertables with compressed chunks (TimescaleDB 2.27:
-- "operation not supported on hypertables with compressed chunks"; 83 of silver's 92 chunks are compressed) and
-- decompress_chunk is forbidden on the shared DB. New nullable double precision *_total columns (metadata-only, instant)
-- are written alongside *_val from the stream-engine release that follows; readers use coalesce(*_total, *_val).
-- History is NOT backfilled: it was rounded when stored, so copying it into float8 gains nothing.
--
-- LOCKING: ADD COLUMN takes ACCESS EXCLUSIVE on the hypertable and every chunk. stream-engine reads/writes these tables
-- continuously, so apply inside a short window with stream-engine stopped (user-approved 2026-10-07); the 3 s lock_timeout
-- keeps a failed attempt from stalling everyone else. Idempotent.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE silver.equipment_values
  ADD COLUMN IF NOT EXISTS gross_production_total double precision,
  ADD COLUMN IF NOT EXISTS net_production_total   double precision,
  ADD COLUMN IF NOT EXISTS scrap_total            double precision,
  ADD COLUMN IF NOT EXISTS process_scrap_total    double precision;
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE bronze.equipment_values_raw
  ADD COLUMN IF NOT EXISTS gross_production_total double precision,
  ADD COLUMN IF NOT EXISTS net_production_total   double precision,
  ADD COLUMN IF NOT EXISTS scrap_total            double precision,
  ADD COLUMN IF NOT EXISTS process_scrap_total    double precision;
COMMIT;

COMMENT ON COLUMN silver.equipment_values.gross_production_total IS 'Exact running gross counter total (float8). Read coalesce(gross_production_total, gross_production_val).';
COMMENT ON COLUMN silver.equipment_values.net_production_total   IS 'Exact running net counter total (float8). Read coalesce(net_production_total, net_production_val).';
COMMENT ON COLUMN silver.equipment_values.scrap_total            IS 'Exact running scrap counter total (float8). Read coalesce(scrap_total, scrap_val).';
COMMENT ON COLUMN silver.equipment_values.process_scrap_total    IS 'Exact running process-scrap counter total (float8). Read coalesce(process_scrap_total, process_scrap_val).';
COMMENT ON COLUMN silver.equipment_values.gross_production_val   IS 'DEPRECATED float4 (exact only to 2^24): use gross_production_total; kept for history and until no reader is left.';
COMMENT ON COLUMN silver.equipment_values.net_production_val     IS 'DEPRECATED float4 (exact only to 2^24): use net_production_total; kept for history and until no reader is left.';
COMMENT ON COLUMN silver.equipment_values.scrap_val              IS 'DEPRECATED float4 (exact only to 2^24): use scrap_total; kept for history and until no reader is left.';
COMMENT ON COLUMN silver.equipment_values.process_scrap_val      IS 'DEPRECATED float4 (exact only to 2^24): use process_scrap_total; kept for history and until no reader is left.';
COMMENT ON COLUMN bronze.equipment_values_raw.gross_production_total IS 'Exact running gross counter total (float8); see silver.equipment_values.';
COMMENT ON COLUMN bronze.equipment_values_raw.net_production_total   IS 'Exact running net counter total (float8); see silver.equipment_values.';
COMMENT ON COLUMN bronze.equipment_values_raw.scrap_total            IS 'Exact running scrap counter total (float8); see silver.equipment_values.';
COMMENT ON COLUMN bronze.equipment_values_raw.process_scrap_total    IS 'Exact running process-scrap counter total (float8); see silver.equipment_values.';
