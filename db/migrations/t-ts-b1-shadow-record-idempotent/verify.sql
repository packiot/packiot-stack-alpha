\pset format unaligned
SET default_transaction_read_only = on;
-- THE B2 GATE, counted by hour window: want windows >= 160 and failing = 0
SELECT 'V1 B2 gate (7 days): distinct hour windows / failing',
       count(DISTINCT substring(detail from '\d{4}-\d{2}-\d{2} \d{2}:\d{2}')), count(*) FILTER (WHERE NOT ok)
  FROM ops.data_invariant_result WHERE source = 'rollup-shadow' AND check_id = 'R1_rollup_twin_vs_truth' AND run_at > now() - interval '7 days';
