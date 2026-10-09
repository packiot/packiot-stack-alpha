-- t-historian-serving-guards / 01 — ANALYTICS (packiot_analytics). Apply as postgres.
-- The historian gateway's least-privilege remote identity (histgw_ro) may read the
-- hourly rollup, so read-api's long-window historian path can sum hours instead of
-- pulling per-second rows through postgres_fdw. The hourly aggregate equals the raw
-- sums exactly (checked 2026-09-25, CPACK: 3,813,676 / 3,018,825 both ways) and is
-- kept 13 months (raw: 90 days).
GRANT SELECT ON silver.equipment_categorical_1hour TO histgw_ro;
