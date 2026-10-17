-- rollback t-postgres-exporter-role — remove the postgres_exporter login.
--
-- FIRST stop postgres-exporter (or point it elsewhere), or it reconnects in a loop. Then run this. The Secrets
-- Manager secret packiot/<env>/postgres-exporter-db-creds is not touched; delete it separately if the role is
-- gone for good.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE r text; s text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'postgres_exporter';
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM postgres_exporter', current_database());
    FOREACH r IN ARRAY ARRAY[
      'ops.data_invariant_result', 'ops.data_invariant_latest', 'ops.data_invariant_timing',
      'ops.retention_drift', 'ops.retention_run', 'ops.cold_export', 'ops.partition_drop_blocked',
      'silver.rollup_invalidation', 'silver.equipment_categorical_1min', 'silver.agg_equipment_values_1min',
      'silver.equipment_categorical_1hour', 'silver.agg_equipment_values_1hour'] LOOP
      IF to_regclass(r) IS NOT NULL THEN EXECUTE format('REVOKE ALL ON %s FROM postgres_exporter', r); END IF;
    END LOOP;
    FOREACH s IN ARRAY ARRAY['ops', 'silver'] LOOP
      IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s) THEN
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM postgres_exporter', s);
      END IF;
    END LOOP;
    REVOKE pg_monitor FROM postgres_exporter;
    DROP OWNED BY postgres_exporter;   -- anything granted by hand later, in this database
    ALTER ROLE postgres_exporter RESET ALL;
    DROP ROLE postgres_exporter;
  END IF;
END $$;

COMMIT;
