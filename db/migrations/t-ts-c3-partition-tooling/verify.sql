-- t-ts-c3-partition-tooling — verify (read-only)
\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 tooling present: 6', count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'ops' AND p.proname IN ('pc_floor','pc_add_partitions','pc_prepare','pc_copy','pc_swap','partition_maintain');
SELECT 'V2 conversions (info): prepared / swapped', count(*), count(swapped_at) FROM ops.pc_state;
