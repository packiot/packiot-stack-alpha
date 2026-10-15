-- t-ts-b4-drop-discrete-1s — drop silver.ca_discrete_changes_1s and its jobs (ADR-0063 Phase B4).
--
-- WHY: its only reader was the status-4 events deriver, which reads silver.equipment_values directly
-- since #1807 (same events under the same keys; golden test against this cagg: 715/715 identical).
-- The cagg costs a ~27 s refresh every 15 min (job 1013), a compression job (1034), a retention job
-- (1046), ~2.7 GB, and 4.8 % of DB time. pg_depend: no view depends on it; no function names it.
--
-- PRECONDITION (checked below): the running stream-engine no longer reads it — #1807 deployed.
-- APPLY: DROP MATERIALIZED VIEW on a cagg locks its raw hypertable (silver.equipment_values); stop
-- the stream-engine writers first (DBA guide rule, as for t-drop-ca-equipment-boxes-1s), apply,
-- start them again. rollback.sql recreates the cagg exactly (captured from staging 2026-10-15).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $mig$
BEGIN
  IF to_regclass('silver.ca_discrete_changes_1s') IS NOT NULL THEN
    PERFORM remove_continuous_aggregate_policy('silver.ca_discrete_changes_1s', if_exists => true);
    PERFORM remove_compression_policy('silver.ca_discrete_changes_1s', if_exists => true);
    PERFORM remove_retention_policy('silver.ca_discrete_changes_1s', if_exists => true);
  END IF;
END $mig$;
-- ops.apply_retention() would otherwise fail on the missing relation
DELETE FROM ops.retention_policy WHERE relation = 'silver.ca_discrete_changes_1s';
DROP MATERIALIZED VIEW IF EXISTS silver.ca_discrete_changes_1s;

COMMIT;
