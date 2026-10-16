-- rollback for t-ts-b2-rollup-cutover — NOT a one-liner, by design. The caggs were dropped; to go back:
--   1. rename each plain table back to <name>__next (and its indexes), restore kind = 'cagg' in ops.retention_policy;
--   2. recreate the five caggs from their definitions (captured in db/migrations/t-ts-b1-rollup-shadow's
--      header comments and the dev seed schema) WITH NO DATA, their refresh/compression/retention policies;
--   3. CALL refresh_continuous_aggregate(...) over the retention window (hours of CPU on staging);
--   4. re-apply t-ts-b1-rollup-shadow (diff/seed helpers) and t-ts-b1-shadow-invariant.
-- The readers never notice either way (same names, same columns). Prefer fixing forward: the twins are
-- recomputable from silver.equipment_values at any time with CALL silver.rollup_backfill(from, to).
\echo 'rollback is a manual procedure, see the comments in this file'
