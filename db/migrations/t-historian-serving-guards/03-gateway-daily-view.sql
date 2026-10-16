-- t-historian-serving-guards / 03 — HISTORIAN GATEWAY. Apply AFTER the first
-- `FULL=1 scripts/historian-ev-daily-rollup.sh` run (the view reads its parquet).
-- COLD daily rollup of equipment_values: one row per (UTC day, equipment), spike-guarded,
-- covering whole days < cold.ev_daily_watermark.covered_until. read-api's long-window path.
CREATE OR REPLACE VIEW cold.equipment_values_daily AS
SELECT r['day']::date                           AS day,
       r['enterprise']::int                     AS id_enterprise,
       r['year']::int                           AS year,
       r['month']::int                          AS month,
       r['id_equipment']::int                   AS id_equipment,
       r['gross_production']::double precision  AS gross_production,
       r['net_production']::double precision    AS net_production,
       r['n_rows']::bigint                      AS n_rows
FROM read_parquet('s3://packiot-staging-historian-639178078294/equipment_values_daily/*/*/*/*.parquet',
                  hive_partitioning => true) r;
COMMENT ON VIEW cold.equipment_values_daily IS
  'Per-day gross/net per equipment from the cold archive (scripts/historian-ev-daily-rollup.sh), spike-guarded like cold.equipment_values. Covers whole UTC days < cold.ev_daily_watermark.covered_until; always filter id_enterprise + year/month (partition prune).';
GRANT SELECT ON cold.equipment_values_daily TO historian_svc;
