-- Restores the static timescaledb_information versions (needs the extension).
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE VIEW ops.retention_drift AS
WITH live AS (
  SELECT (jobs.hypertable_schema::text || '.'::text) || jobs.hypertable_name::text AS relation,
         (jobs.config ->> 'drop_after'::text)::interval AS live_keep
    FROM timescaledb_information.jobs WHERE jobs.proc_name = 'policy_retention'::name)
SELECT COALESCE(p.relation, l.relation) AS relation, p.keep AS catalog_keep, l.live_keep,
       CASE WHEN p.relation IS NULL THEN 'live policy not in catalog'::text
            WHEN p.keep IS NULL THEN 'catalog=forever but live drops'::text
            WHEN l.relation IS NULL THEN 'catalog bounds but no live policy'::text
            ELSE 'keep differs'::text END AS problem
  FROM (SELECT relation, kind, time_expr, keep, tier, purge_order, cold_copy, rationale, updated_at
          FROM ops.retention_policy WHERE kind = ANY (ARRAY['hypertable'::text, 'cagg'::text])) p
  FULL JOIN live l USING (relation)
 WHERE p.keep IS DISTINCT FROM l.live_keep;
DROP FUNCTION IF EXISTS ops.ts_retention_live();
COMMIT;
-- apply_retention / sbx_mirror_silver_day: the new bodies behave identically with the extension;
-- re-run db/migrations/t-retention-catalog/01-up.sql for the original apply_retention text if needed.
