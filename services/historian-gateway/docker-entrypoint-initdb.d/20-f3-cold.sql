-- 20-f3-cold.sql — ADR-0065 P2: serve archived F3 days of silver.equipment_values from the analytics cold export.
-- Runs after 10-historian-gateway.sh on a FRESH volume. On a RUNNING gateway apply the same file by hand (idempotent):
--   docker exec -i hist-gateway sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < 20-f3-cold.sql
-- Needs the analytics grant db/migrations/t-adr0065-p2-histgw-cold-export.
--
-- WHY: analytics drops raw partitions past retention once each tenant-day has a VERIFIED Parquet copy
-- (ops.partition_maintain + ops.cold_export, ADR-0065 P0/P1). Tenants WITH legacy history (CPACK, Incoplast) are
-- already served from the legacy copy (ev_union_boundary, legacy-priority) — unchanged here. Tenants WITHOUT legacy
-- (Bispharma) were served from hot only, so a dropped partition would vanish from the historian.
--
-- RULE (per tenant): f3_union_boundary.cutover_ts = the end of the verified archive (least of: the newest verified
-- day end, the first unverified day). The F3 archive serves ts < cutover_ts, hot serves ts >= cutover_ts. The legacy
-- copy still wins below its own cutover. Because the boundary trails "now" by ~2 days and partitions are dropped ~90
-- days back, every day is always in exactly one branch: no gap, no double count — even if a refresh is missed (a
-- stale boundary only means hot serves a few more days it still holds).
-- The boundary is refreshed by refresh-f3-cutover.sql (end of every nightly cold export) and at the end of this file.
--
-- Optional psql variable / env HISTORIAN_F3_ROOT overrides the archive root (tests use a local directory);
-- default s3://$HISTORIAN_BUCKET.
\set ON_ERROR_STOP 1
SET search_path = cold, public;
\getenv bucket HISTORIAN_BUCKET
\getenv f3_root HISTORIAN_F3_ROOT
\if :{?f3_root}
\elif :{?bucket}
  \set f3_root 's3://' :bucket
\else
  \warn 'neither HISTORIAN_F3_ROOT nor HISTORIAN_BUCKET is set'
  SELECT historian_bucket_unset;
\endif

-- HOT side of the manifest (pinned columns, like the other live.* tables)
DROP FOREIGN TABLE IF EXISTS live.cold_export;
CREATE FOREIGN TABLE live.cold_export (
  relation      text,
  id_enterprise integer,
  period_lo     timestamptz,
  period_hi     timestamptz,
  verified_at   timestamptz
) SERVER live_pg OPTIONS (schema_name 'ops', table_name 'cold_export');

-- COLD F3 archive, same served columns as cold.equipment_values (the legacy copy). F3 rows are already guarded by
-- the engine (#1544), so the legacy spike guard does not apply. hive partitions: enterprise/year/month/day.
SELECT format($v$CREATE OR REPLACE VIEW cold.equipment_values_f3 AS
SELECT r['ts_value']::timestamptz                      AS ts_value,
       r['enterprise']::int                            AS id_enterprise,
       r['year']::int                                  AS year,
       r['month']::int                                 AS month,
       r['id_equipment']::int                          AS id_equipment,
       r['gross_production_incr']::double precision    AS gross_production_incr,
       r['net_production_incr']::double precision      AS net_production_incr,
       r['speed']::double precision                    AS speed
  FROM read_parquet(%L, hive_partitioning => true) r$v$, :'f3_root' || '/silver/equipment_values/*/*/*/*/f3.parquet') \gexec

CREATE TABLE IF NOT EXISTS public.f3_union_boundary (
  id_enterprise int PRIMARY KEY,
  cutover_ts    timestamptz NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.f3_union_boundary IS
  'ADR-0065 P2: per tenant, the end of the VERIFIED analytics cold export (ops.cold_export). The F3 archive serves '
  'silver.equipment_values below cutover_ts, hot at/after it (legacy copy still wins below ev_union_boundary). '
  'Refreshed by refresh-f3-cutover.sql after every nightly export.';

-- the union: hot / legacy cold (unchanged) / F3 cold
CREATE OR REPLACE VIEW silver.equipment_values AS
  SELECT lv.ts_value,
         lv.id_enterprise,
         EXTRACT(YEAR  FROM lv.ts_value)::int  AS year,
         EXTRACT(MONTH FROM lv.ts_value)::int  AS month,
         lv.id_equipment,
         lv.gross_production_incr,
         lv.net_production_incr,
         lv.speed
    FROM live.equipment_values lv
    LEFT JOIN ev_union_boundary c ON c.id_enterprise = lv.id_enterprise
    LEFT JOIN f3_union_boundary f ON f.id_enterprise = lv.id_enterprise
   WHERE (c.cutover_ts IS NULL OR lv.ts_value > c.cutover_ts)
     AND (f.cutover_ts IS NULL OR lv.ts_value >= f.cutover_ts)
  UNION ALL
  SELECT h.ts_value,
         h.id_enterprise,
         h.year,
         h.month,
         h.id_equipment,
         h.gross_production_incr,
         h.net_production_incr,
         h.speed
    FROM cold.equipment_values h
    JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ev_promoted
  UNION ALL
  SELECT x.ts_value,
         x.id_enterprise,
         x.year,
         x.month,
         x.id_equipment,
         x.gross_production_incr,
         x.net_production_incr,
         x.speed
    FROM cold.equipment_values_f3 x
    JOIN f3_union_boundary f ON f.id_enterprise = x.id_enterprise AND x.ts_value < f.cutover_ts
    LEFT JOIN ev_union_boundary c ON c.id_enterprise = x.id_enterprise
   WHERE c.cutover_ts IS NULL OR x.ts_value > c.cutover_ts;

-- explicit grants (default privileges cover new objects too; this keeps a re-applied gateway exact)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'historian_svc') THEN
    GRANT SELECT ON cold.equipment_values_f3, public.f3_union_boundary, live.cold_export, silver.equipment_values TO historian_svc;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudbeaver_histro') THEN
    GRANT SELECT ON cold.equipment_values_f3, public.f3_union_boundary, live.cold_export TO cloudbeaver_histro;
  END IF;
END $$;

-- first boundary (same statements as ../refresh-f3-cutover.sql, which the nightly hook runs; only this directory is
-- mounted into the container, so the refresh is inlined here)
BEGIN;
CREATE TEMP TABLE _f3b ON COMMIT DROP AS
SELECT id_enterprise,
       least(max(period_hi) FILTER (WHERE verified_at IS NOT NULL),
             coalesce(min(period_lo) FILTER (WHERE verified_at IS NULL), 'infinity'::timestamptz)) AS cutover_ts
  FROM live.cold_export
 WHERE relation = 'silver.equipment_values'
 GROUP BY id_enterprise
HAVING max(period_hi) FILTER (WHERE verified_at IS NOT NULL) IS NOT NULL;
INSERT INTO public.f3_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT id_enterprise, cutover_ts, now() FROM _f3b
ON CONFLICT (id_enterprise) DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
DELETE FROM public.f3_union_boundary b WHERE NOT EXISTS (SELECT 1 FROM _f3b x WHERE x.id_enterprise = b.id_enterprise);
COMMIT;
SELECT 'f3_union_boundary', id_enterprise, cutover_ts FROM public.f3_union_boundary ORDER BY 2;
