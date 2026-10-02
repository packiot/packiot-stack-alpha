package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// STRANDED-FLAG SWEEP (2026-10-01). recalc_needed is a work queue, and every
// consumer only drains the rows its eligibility can reach. A flag left on a row
// that is (or ages) outside that reach is a permanent phantom: it never drains,
// it inflates every backlog metric, and — worse — it HIDES a repair that wanted
// a recompute that will never happen. Found live: 2,058 CPACK/twin PO runtime
// rows + 933 headers flagged since June (outside the 1-month window; 666 of the
// runs carried data-hole values vs the legacy oracle), and 7,770 Bispharma
// machine shift rows (tp=1 of a non-machine-level enterprise — never eligible).
//
// This job clears exactly those flags and logs a WARN with the count + sample
// keys, so a stranded repair is SEEN (and redone by hand with the engine's own
// statements) instead of silently ignored. It never touches a row any consumer
// can still reach, so it cannot race the live passes: each predicate is the
// NEGATION of the corresponding eligibility.
type StrandedScope struct {
	POWindow                string // PO compute/recalc window (PO_RECALC_WINDOW), e.g. "1 month"
	MachineLevelEnterprises []int  // shift eligibility: tp=1 rows of these enterprises ARE computed
	HourHorizon             string // hour backfill reach ("10 days"); "" = skip the hour sweep
}

type strandedStmt struct {
	table, sql string
	args       []string // which scope values the statement binds, in $n order: "window", "ml", "hour"
}

// Each statement: clear, then report count + up to 10 sample keys.
func strandedStatements(d flows.Dest, s StrandedScope) []strandedStmt {
	out := []strandedStmt{
		{"production_orders_runtime", fmt.Sprintf(`
	WITH c AS (
	    UPDATE %[1]s.production_orders_runtime SET recalc_needed = false
	     WHERE recalc_needed
	       AND upper(runtime_timerange) < now() - $1::interval   -- closed before the compute window
	    RETURNING id_production_order_runtime::text AS k)
	SELECT count(*), COALESCE((array_agg(k ORDER BY k))[1:10], '{}') FROM c`, d.GoldSchema), []string{"window"}},
		{"production_orders", fmt.Sprintf(`
	WITH c AS (
	    UPDATE %[1]s.production_orders SET recalc_needed = false
	     WHERE recalc_needed AND status IN (3, 4)                 -- finished; running POs re-flag every pass
	       AND COALESCE(ts_end, ts_start) < now() - $1::interval -- recalc: ts_start OR ts_end in the window
	    RETURNING id_production_order::text AS k)
	SELECT count(*), COALESCE((array_agg(k ORDER BY k))[1:10], '{}') FROM c`, d.RefSchema), []string{"window"}},
		{"equipment_oee_shift", fmt.Sprintf(`
	WITH c AS (
	    UPDATE %[1]s.equipment_oee_shift e SET recalc_needed = false
	      FROM %[2]s.equipments eq
	     WHERE e.recalc_needed AND eq.id_equipment = e.id_equipment
	       AND e.ts_value <= now()
	       AND (e.ts_value < now() - interval '30 days'           -- shift eligibility horizon
	            OR (eq.tp_equipment = 1 AND NOT (eq.id_enterprise = ANY($1::int[]))))  -- never in scope
	    RETURNING e.id_equipment || '@' || e.ts_value AS k)
	SELECT count(*), COALESCE((array_agg(k ORDER BY k))[1:10], '{}') FROM c`, d.GoldSchema, d.RefSchema), []string{"ml"}},
	}
	if s.HourHorizon != "" {
		out = append(out, strandedStmt{"equipment_oee_hourly", fmt.Sprintf(`
	WITH c AS (
	    UPDATE %[1]s.equipment_oee_hourly e SET recalc_needed = false
	      FROM %[2]s.equipments eq
	     WHERE e.recalc_needed AND eq.id_equipment = e.id_equipment
	       AND (e.ts_value < now() - $1::interval                 -- hour backfill horizon
	            OR eq.tp_equipment = 1)                           -- hour grain is tp>1 only (#256)
	    RETURNING e.id_equipment || '@' || e.ts_value AS k)
	SELECT count(*), COALESCE((array_agg(k ORDER BY k))[1:10], '{}') FROM c`, d.GoldSchema, d.RefSchema), []string{"hour"}})
	}
	return out
}

// RunStrandedSweep clears stranded flags for one destination; returns rows cleared per table.
func RunStrandedSweep(ctx context.Context, d flows.Dest, s StrandedScope, logger *slog.Logger) (map[string]int64, error) {
	ml := s.MachineLevelEnterprises
	if ml == nil {
		ml = []int{}
	}
	hh := s.HourHorizon
	if hh == "" {
		hh = "10 days"
	}
	cleared := map[string]int64{}
	for _, st := range strandedStatements(d, s) {
		var n int64
		var sample []string
		vals := map[string]any{"window": s.POWindow, "ml": ml, "hour": hh}
		args := make([]any, len(st.args))
		for i, a := range st.args {
			args[i] = vals[a]
		}
		if err := d.Pool.QueryRow(ctx, st.sql, args...).Scan(&n, &sample); err != nil {
			return cleared, fmt.Errorf("stranded %s: %w", st.table, err)
		}
		cleared[st.table] = n
		if n > 0 {
			logger.Warn("stranded recalc flags cleared — these rows can never be recomputed by the engine; if a repair flagged them, redo it with the engine's statements",
				slog.String("dest", d.Name), slog.String("table", st.table), slog.Int64("rows", n), slog.Any("sample", sample))
		}
	}
	return cleared, nil
}

// LoopStrandedSweep runs the sweep hourly per destination.
func LoopStrandedSweep(ctx context.Context, dests []flows.Dest, s StrandedScope, logger *slog.Logger, obs jobs.Observer) {
	jobs.Loop(ctx, jobs.Job{Name: "stranded-flag-sweep", Every: time.Hour, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			if _, err := RunStrandedSweep(ctx, d, s, logger); err != nil {
				logger.Warn("stranded-flag-sweep failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
		}
		return firstErr
	}}, logger, obs)
}
