// compute.go — po-runtime-compute (ledger name), ported from prod's
// piot_get_equipment_production_order_runtime_test ('_test' IS
// production — the plain generation is commented out in the
// dispatcher). Per-runtime-row two-phase pass, set-based.
//
// EQUIVALENCE ARGUMENT (each claim attackable):
//   - Phase A (value sums → gross/net/oee_q/speed): prod's aggregate
//     SELECT INTO always sets FOUND → ALWAYS updates (zero-fills
//     no-data rows, clears recalc_needed). Ported as eligible-set
//     LEFT JOIN + COALESCE — the exact lesson the harness taught on
//     recalc (bug class handled by design this time).
//   - Phase B (event overlap sums → running/stopped): prod's SELECT
//     has GROUP BY — zero groups when no overlapping events → FOUND
//     FALSE → update SKIPPED. Ported as INNER join: rows without
//     events keep their previous running/stopped. GENUINELY
//     CONDITIONAL — do not "fix" into a left join.
//   - Overlap math verbatim: epoch(least(coalesce(ee.ts_end,now()),
//     coalesce(upper,now())) - greatest(ts_event, lower)); running =
//     status 6; stopped = status IN (5,10,11).
//   - ideal_production_speed: prod computes it but every USE is
//     commented out — dead computation, not ported (documented).
//   - SET LOCAL TIME ZONE: same bounded divergence class as recalc —
//     only the now()-'1 month' boundary is tz-sensitive (≤1h edge
//     under DST); consistent-boundary behavior chosen.
//   - Tails verbatim: re-flag open ranges (upper IS NULL) + ranges
//     that ended within 48h.
//   - Ordering: prod's dispatcher runs compute THEN recalc each pass
//     with per-step fail-soft commits — preserved by LoopRefresh
//     (one job, ordered steps, drop-per-step).
//
// GUARDRAIL STATEMENT: updates production_orders_runtime metric
// columns + recalc_needed by (id_equipment, lower(runtime_timerange));
// reads equipment_values + equipment_events. No range writes — the
// EXCLUDE constraint is not in play.
package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// Phase A: value sums — ALWAYS updates eligible rows (see argument).
const computeValuesSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi
	      FROM %[1]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	), sums AS (
	    SELECT el.id_equipment, el.lo,
	           sum(ca.gross_production_incr) AS gross,
	           sum(ca.net_production_incr)   AS net,
	           avg(ca.speed)                 AS speed
	      FROM eligible el
	      JOIN %[1]s.equipment_values ca
	        ON ca.id_equipment = el.id_equipment
	       AND ca.ts_value >= now() - $1::interval
	       AND ca.ts_value >= el.lo AND ca.ts_value < el.hi
	     GROUP BY el.id_equipment, el.lo
	)
	UPDATE %[1]s.production_orders_runtime e SET
	       gross_production = COALESCE(s.gross, 0),
	       net_production   = COALESCE(s.net, 0),
	       oee_q            = COALESCE(s.net / NULLIF(s.gross, 0), 0),
	       speed            = COALESCE(s.speed, 0),
	       recalc_needed    = false
	  FROM eligible el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.lo = el.lo
	 WHERE e.id_equipment = el.id_equipment
	   AND lower(e.runtime_timerange) = el.lo`

// Phase B: event overlap sums — CONDITIONAL (inner join; prod's
// GROUP BY → FOUND false when no overlapping events).
const computeEventsSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, e.runtime_timerange,
	           lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi
	      FROM %[1]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	), ev AS (
	    SELECT el.id_equipment, el.lo,
	           COALESCE(sum(CASE WHEN ee.status = 6 THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi)
	                                 - greatest(ee.ts_event, el.lo))) END), 0) AS running,
	           COALESCE(sum(CASE WHEN ee.status IN (5, 10, 11) THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi)
	                                 - greatest(ee.ts_event, el.lo))) END), 0) AS stopped
	      FROM eligible el
	      JOIN %[1]s.equipment_events ee
	        ON ee.id_equipment = el.id_equipment
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && el.runtime_timerange
	       AND ee.ts_event >= now() - $1::interval AND ee.ts_event < now()
	     GROUP BY el.id_equipment, el.lo
	)
	UPDATE %[1]s.production_orders_runtime e SET
	       running_time = ev.running,
	       stopped_time = ev.stopped
	  FROM ev
	 WHERE e.id_equipment = ev.id_equipment
	   AND lower(e.runtime_timerange) = ev.lo`

// NOTE (phase order): prod runs phase A (which CLEARS recalc_needed)
// before phase B reads its own eligible set — but prod's loop
// evaluates BOTH phases per row from the SAME loop selection. The
// set-based port therefore snapshots eligibility ONCE per pass: both
// statements share the predicate, and phase B runs BEFORE phase A so
// the flag-clear cannot shrink its set. Outputs identical; order of
// column writes within a pass is not observable between passes.

const computeReflagOpenSQL = `
	UPDATE %[1]s.production_orders_runtime SET recalc_needed = true
	 WHERE upper(runtime_timerange) IS NULL`

const computeReflagRecentSQL = `
	UPDATE %[1]s.production_orders_runtime SET recalc_needed = true
	 WHERE upper(runtime_timerange) > now() - interval '48 hours'`

// RunCompute executes one compute pass for one destination.
func RunCompute(ctx context.Context, d flows.Dest, window string) (int64, error) {
	// Phase B first (see NOTE): its eligible set must predate A's clear.
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(computeEventsSQL, d.EvSchema, d.RefSchema), window); err != nil {
		return 0, fmt.Errorf("compute events: %w", err)
	}
	tag, err := d.Pool.Exec(ctx, fmt.Sprintf(computeValuesSQL, d.EvSchema, d.RefSchema), window)
	if err != nil {
		return 0, fmt.Errorf("compute values: %w", err)
	}
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(computeReflagOpenSQL, d.EvSchema)); err != nil {
		return tag.RowsAffected(), fmt.Errorf("reflag open: %w", err)
	}
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(computeReflagRecentSQL, d.EvSchema)); err != nil {
		return tag.RowsAffected(), fmt.Errorf("reflag recent: %w", err)
	}
	return tag.RowsAffected(), nil
}

// LoopRefresh = the dispatcher (ledger: po-runtime-refresh): compute
// then recalc, ordered, drop-per-step (prod's fail-soft blocks).
func LoopRefresh(ctx context.Context, dests []flows.Dest, window string, exclEnterprises []int, every time.Duration, logger *slog.Logger, obs jobs.Observer, extra func(context.Context, flows.Dest) error) {
	logger.Info("po-runtime-refresh started (P3b dispatcher: compute → recalc)")
	jobs.Loop(ctx, jobs.Job{Name: "po-runtime-refresh", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			if _, err := RunCompute(ctx, d, window); err != nil {
				logger.Warn("po-runtime-compute failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			if _, err := RunRecalc(ctx, d, window, exclEnterprises); err != nil {
				logger.Warn("po-runtime-recalc failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			if extra != nil {
				// the dispatcher's third step (uns jobs), fail-soft
				if err := extra(ctx, d); err != nil {
					logger.Warn("po-refresh extra step failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
					if firstErr == nil {
						firstErr = err
					}
				}
			}
		}
		return firstErr
	}}, logger, obs)
}

// Parity accessors (single-source emission).
func ComputeValuesSQLForParity() string    { return computeValuesSQL }
func ComputeEventsSQLForParity() string    { return computeEventsSQL }
func ComputeReflagOpenForParity() string   { return computeReflagOpenSQL }
func ComputeReflagRecentForParity() string { return computeReflagRecentSQL }
