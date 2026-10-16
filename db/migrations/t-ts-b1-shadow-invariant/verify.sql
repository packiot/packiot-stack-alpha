-- t-ts-b1-shadow-invariant — verify (read-only)
\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 stream_engine may record: t', has_function_privilege('stream_engine', 'silver.rollup_shadow_record(timestamptz, timestamptz)', 'EXECUTE');
SELECT 'V2 hours recorded in the last 24 h (info; ~24 once the tick runs)', count(DISTINCT run_at) FROM ops.data_invariant_result
 WHERE source = 'rollup-shadow' AND check_id = 'R1_rollup_twin_vs_truth' AND run_at > now() - interval '24 hours';
-- THE B2 GATE: 7 days of hourly R1 rows, all ok. Want: hours_recorded >= 160 and failing = 0.
SELECT 'V3 B2 gate over 7 days: hours_recorded / failing', count(DISTINCT run_at), count(*) FILTER (WHERE NOT ok)
  FROM ops.data_invariant_result WHERE source = 'rollup-shadow' AND check_id = 'R1_rollup_twin_vs_truth' AND run_at > now() - interval '7 days';
