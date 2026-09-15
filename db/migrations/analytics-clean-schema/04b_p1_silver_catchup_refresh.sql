-- P1 SILVER catch-up refresh — oldest-first, BOTTOM-UP (parents read the child's
-- materialization, so refresh 1min -> 10min -> 1hour -> 1day). Avoids the #196
-- read-hole (a full explicit-range refresh, not policy-tail only). NOT runnable
-- inside a transaction block — run via psql autocommit.
-- Applied on staging 2026-09-08 over the full data range (2026-07-08 -> now).
CALL refresh_continuous_aggregate('silver.equipment_metrics_1min',  '2026-07-01 00:00+00', '2026-09-09 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_metrics_10min', '2026-07-01 00:00+00', '2026-09-09 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_metrics_1hour', '2026-07-01 00:00+00', '2026-09-09 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_metrics_1day',  '2026-07-01 00:00+00', '2026-09-09 00:00+00');
-- Proven result: 1min=1,523,824  10min=176,238  1hour=35,489  1day=2,439 buckets.
