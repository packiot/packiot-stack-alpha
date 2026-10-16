-- t-data-invariants-timing — per-check runtime for the invariant battery (2026-10-02)
--   Why: the whole run (Z_invariants_run) took 38–230 s against a 600 s budget during the
--   10-01 recompute load. Before splitting the job we need to know WHICH checks are slow.
--   How: recorded_at defaults to clock_timestamp(), so every result row carries the wall
--   time it was written — no change to the procedure's INSERTs (they are positional and leave
--   trailing columns to their defaults). A check's runtime = its first row's recorded_at minus
--   the previous check's last row (run_at for the first check). A check that emits no rows
--   (e.g. zero tenants in scope) folds into the next check's time.
--   Added without a table rewrite: ADD COLUMN (no default) + SET DEFAULT → old rows stay NULL.
-- Exposed as pg_data_invariant_check_seconds (monitoring/postgres-exporter/queries.yaml);
-- DataInvariantsSlow (monitoring/prometheus/rules.yml) fires when runs average > 400 s.
-- Rollback: rollback.sql.
BEGIN;

ALTER TABLE ops.data_invariant_result ADD COLUMN IF NOT EXISTS recorded_at timestamptz;
ALTER TABLE ops.data_invariant_result ALTER COLUMN recorded_at SET DEFAULT clock_timestamp();

CREATE OR REPLACE VIEW ops.data_invariant_timing AS
WITH per_check AS (
  SELECT run_at, check_id, min(recorded_at) first_at, max(recorded_at) last_at
    FROM ops.data_invariant_result
   WHERE source = 'db' AND recorded_at IS NOT NULL
   GROUP BY run_at, check_id
)
SELECT run_at, check_id,
       round(extract(epoch FROM first_at - coalesce(lag(last_at) OVER w, run_at))::numeric, 2) AS seconds
  FROM per_check
WINDOW w AS (PARTITION BY run_at ORDER BY first_at);

COMMENT ON VIEW ops.data_invariant_timing IS
  'Seconds each in-DB invariant check took per run (t-data-invariants-timing). Slowest in the latest run: SELECT * FROM ops.data_invariant_timing WHERE run_at = (SELECT max(run_at) FROM ops.data_invariant_timing) ORDER BY seconds DESC;';

GRANT SELECT ON ops.data_invariant_timing TO PUBLIC;

COMMIT;
