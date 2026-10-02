-- Restores the procedure without C6 (idempotent; keeps results/job).
\i db/migrations/t-data-invariants-v3/01-up.sql
DELETE FROM ops.data_invariant_result WHERE check_id = 'C6_shift_gross_vs_lead_silver_3d';
