-- t-adr0065-p2-histgw-cold-export — ADR-0065 P2: the historian gateway reads the cold-export manifest (2026-10-16).
-- hist-gateway mounts ops.cold_export through postgres_fdw (user mapping → histgw_ro) to derive, per tenant, the
-- boundary below which the verified Parquet archive (s3://…/silver/equipment_values/…/f3.parquet) serves the union
-- silver.equipment_values instead of the hot table. histgw_ro already has USAGE on ops; it needs SELECT here.
\set ON_ERROR_STOP 1
BEGIN;
GRANT SELECT ON ops.cold_export TO histgw_ro;
COMMIT;
