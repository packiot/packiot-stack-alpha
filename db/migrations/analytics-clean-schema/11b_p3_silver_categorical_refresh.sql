-- P3 — categorical companion catch-up (oldest-first, bottom-up).
-- statement_timeout disabled: the 1min base tier re-scans ~2 months of RAW at
-- the 18-key categorical grain (heavy one-shot); ongoing refresh is incremental
-- via the policies in 11c. Base tier is chunked by ~week to bound each INSERT.
SET statement_timeout = 0;

CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-07-01', '2026-07-15');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-07-15', '2026-08-01');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-08-01', '2026-08-15');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-08-15', '2026-09-01');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-09-01', '2026-09-10');

-- WATERMARK LESSON: refresh the HIGHER tiers only up to a COMPLETED bucket boundary
-- (here 2026-09-08 12:00, == ca_agg_1hour's watermark), NEVER to a future date. A cagg
-- serves buckets BELOW its watermark from the frozen materialization; materializing the
-- current *incomplete* hour snapshots it stale and it stays stale until the next policy
-- refresh (the fn-gate caught exactly this: current-hour production 56 vs live 81). Leaving
-- the current bucket ABOVE the watermark lets the real-time union (materialized_only=false)
-- compute it fresh from tier-1 — identical freshness to ca_agg. The policies (11c, end_offset
-- keeps the watermark ~1 tier-width behind) maintain this invariant going forward.
CALL refresh_continuous_aggregate('silver.equipment_categorical_10min', '2026-07-01', '2026-09-08 12:00');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1hour', '2026-07-01', '2026-09-08 12:00');
