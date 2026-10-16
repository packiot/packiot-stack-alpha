-- t244b · fix a gap in the t244 pool DDL caught by the stream-engine writer repoint:
-- customer_reports.production_data_sync.indice_geral was bigint with NO default, but
-- the legacy production_data_sync_enterprise_06.indice_geral had
-- DEFAULT nextval(...) NOT NULL. The sync06 state machine never INSERTs indice_geral
-- (relies on the default); without it pool rows get NULL, breaking Condition-6 dedupe
-- ordering, the logics=9 LAG/LEAD prev_indice_geral, and serving.production_data_sync.uniqueid.
-- A single global sequence preserves per-tenant monotonic ordering (rows ordered by
-- indice_geral WITHIN customer_id). Pool is empty on staging → SET NOT NULL is safe.
BEGIN;
CREATE SEQUENCE IF NOT EXISTS customer_reports.production_data_sync_indice_geral_seq;
ALTER TABLE customer_reports.production_data_sync
  ALTER COLUMN indice_geral SET DEFAULT nextval('customer_reports.production_data_sync_indice_geral_seq'::regclass),
  ALTER COLUMN indice_geral SET NOT NULL;
COMMIT;
