-- Restores the procedure without V3 (idempotent; keeps results/job).
\i db/migrations/t-data-invariants/01-up.sql
DELETE FROM ops.data_invariant_result WHERE check_id = 'V3_unbacked_increments_2h';
