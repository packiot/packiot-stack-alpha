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
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// Phase A: value sums — ALWAYS updates eligible rows (see argument).
//
// SPLIT-INSTRUMENTATION (line-metered clients, e.g. ent5 Bispharma): a PO runs on
// a tp=3 LINE, but the line's counters are emitted by a MEMBER machine
// (equipments.gross_machine names it; NULL for self-metered equipment). Resolve
// the counter source as COALESCE(gross_machine, id_equipment) so a line-PO reads
// its member's counters instead of the (empty) line row. This MIRRORS
// line_lead.go's gross_id resolution, but at the PO-runtime grain and with a
// DIFFERENT fallback base: id_equipment, NOT lead_machine. This pass is
// PO-equipment-centric — a self-metered line (gross_machine NULL, lead_machine
// SET, incl. every CPACK line) must keep reading its OWN rows, so the COALESCE
// must never fall through to lead_machine. It is a byte-identical NO-OP wherever
// gross_machine IS NULL (all tp=1 machines + all self-metered lines).
const computeValuesSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           eq.gross_machine,
	           COALESCE(eq.gross_machine, e.id_equipment) AS gross_src
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	), sums AS (
	    SELECT el.id_equipment, el.lo,
	           sum(ca.gross_production_incr) AS gross,
	           sum(ca.net_production_incr)   AS net,
	           avg(ca.speed)                 AS speed
	      FROM eligible el
	      JOIN %[3]s.equipment_values ca
	        ON ca.id_equipment = el.gross_src
	       AND ca.ts_value >= now() - $1::interval
	       AND ca.ts_value >= el.lo AND ca.ts_value < el.hi
	     GROUP BY el.id_equipment, el.lo
	)
	UPDATE %[4]s.production_orders_runtime e SET
	       gross_production = COALESCE(s.gross, 0),
	       -- gross-only reconciliation (line_lead's "gross-only ⇒ net=gross"): a
	       -- split-instrumentation member emits the input counter only (no net), so
	       -- net falls back to gross (quality 1.0). GATED on gross_machine IS NOT NULL
	       -- so a self-metered PO with a genuine net=0 (e.g. an all-scrap run) is
	       -- left untouched — the reconciliation reaches ONLY line-metered lines.
	       net_production   = CASE WHEN el.gross_machine IS NOT NULL AND COALESCE(s.net, 0) = 0
	                               THEN COALESCE(s.gross, 0) ELSE COALESCE(s.net, 0) END,
	       oee_q            = GREATEST(LEAST(COALESCE(
	                            (CASE WHEN el.gross_machine IS NOT NULL AND COALESCE(s.net, 0) = 0
	                                  THEN COALESCE(s.gross, 0) ELSE COALESCE(s.net, 0) END)
	                            / NULLIF(s.gross, 0), 0), 1), 0), -- ADR-0037 clamp (net≤gross)
	       speed            = COALESCE(s.speed, 0),
	       recalc_needed    = false
	  FROM eligible el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.lo = el.lo
	 WHERE e.id_equipment = el.id_equipment
	   AND lower(e.runtime_timerange) = el.lo`

// Phase B: event overlap sums — CONDITIONAL (inner join; prod's
// GROUP BY → FOUND false when no overlapping events).
// ev_src mirrors Phase A's gross_src: for a split-instrumented line-PO the
// availability events (the count-silence-derived stops, ADR-0010) land on the
// gross_machine MEMBER, not the empty line row — so read them from there. Reading
// a SINGLE member (not the whole line's interleaved member streams) also sidesteps
// the double-count the LEAST clamp below guards against. NO-OP where gross_machine
// IS NULL (self-metered lines read their own events, as before).
const computeEventsSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, e.runtime_timerange,
	           lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           COALESCE(eq.gross_machine, e.id_equipment) AS ev_src
	      FROM %[4]s.production_orders_runtime e
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
	      JOIN %[3]s.equipment_events ee
	        ON ee.id_equipment = el.ev_src
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && el.runtime_timerange
	       AND ee.ts_event >= now() - $1::interval AND ee.ts_event < now()
	     GROUP BY el.id_equipment, el.lo
	)
	UPDATE %[4]s.production_orders_runtime e SET
	       -- #253: bound to the PO wall-clock span, matching hour.go/shift.go/line_lead.go
	       -- (running_time = LEAST(running, ts_total)). ev.running SUMS status=6 event
	       -- durations, which double-counts when a tp=3 line carries interleaved
	       -- member-machine event streams → running_time can exceed elapsed time (the
	       -- 34–78× overflow the F3 sentinel flags). running_time can never physically
	       -- exceed the PO's wall-clock span; this enforces that invariant in the
	       -- computation (NOT a DQ clamp). No-op on clean single-stream data.
	       running_time = LEAST(ev.running, GREATEST(extract(epoch FROM (COALESCE(upper(e.runtime_timerange), now()) - lower(e.runtime_timerange))), 0)),
	       stopped_time = ev.stopped
	  FROM ev
	 WHERE e.id_equipment = ev.id_equipment
	   AND lower(e.runtime_timerange) = ev.lo`

// Phase B2 (FU#8): the PO-grain availability write path. available_time and
// planned_downtime are NEVER written to production_orders_runtime by any code
// path — the legacy PL/pgSQL had these assignments COMMENTED OUT and the Go port
// reproduced it, so recalc.go sums NULLs and oee_a = running/available and oee_p's
// time factor both collapse to 0 platform-wide (the Jan-2024 PO-grain A/P gap).
//
// This mirrors hour.go's math onto the PO grain: ts_total = the PO's own
// runtime_timerange wall-clock span; available_time = ts_total − LEAST(planned,
// ts_total); planned_downtime = LEAST(planned, ts_total). The planned predicate
// (%[6]s = plannedDowntimeExpr) reads ee.planned_downtime — the PO grain uses the
// default (no R3c changeover reclassification, matching recalc.go's scope note).
// Events read from ev_src (gross_machine or self), identical to computeEventsSQL.
// ideal_production is intentionally NOT written: recalc.go's oee_p recomputes the
// ideal factor from production_orders.ideal_production_speed, not this column.
//
// Flag-gated (POAvailabilityEnabled, default OFF) → not run → available_time stays
// NULL → byte-identical to today (golden-fixture parity). Flip to activate.
const computeAvailabilitySQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, e.runtime_timerange,
	           lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           COALESCE(eq.gross_machine, e.id_equipment) AS ev_src
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	), ev AS (
	    SELECT el.id_equipment, el.lo,
	           GREATEST(extract(epoch FROM (el.hi - el.lo)), 0) AS ts_total,
	           COALESCE(sum(CASE WHEN %[6]s THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi)
	                                 - greatest(ee.ts_event, el.lo))) END), 0) AS planned
	      FROM eligible el
	      JOIN %[3]s.equipment_events ee
	        ON ee.id_equipment = el.ev_src
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && el.runtime_timerange
	       AND ee.ts_event >= now() - $1::interval AND ee.ts_event < now()
	     GROUP BY el.id_equipment, el.lo, el.hi
	)
	UPDATE %[4]s.production_orders_runtime e SET
	       available_time   = GREATEST(ev.ts_total - LEAST(ev.planned, ev.ts_total), 0)::int,
	       planned_downtime = LEAST(ev.planned, ev.ts_total)::int
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
	UPDATE %[4]s.production_orders_runtime SET recalc_needed = true
	 WHERE upper(runtime_timerange) IS NULL`

const computeReflagRecentSQL = `
	UPDATE %[4]s.production_orders_runtime SET recalc_needed = true
	 WHERE upper(runtime_timerange) > now() - interval '48 hours'`

// computeOverflowDiagSQL mirrors computeEventsSQL's eligible+ev CTEs but,
// instead of updating, RETURNS the eligible rows whose computed running/
// stopped exceed a 32-bit integer — i.e. the exact rows that make the UPDATE
// raise SQLSTATE 22003 (running_time/stopped_time are int4). Run only on
// error, so an otherwise-opaque, intermittent overflow (a corrupt PO range or
// a far-future event ts_end producing an absurd interval) names the offending
// PO in the logs instead of vanishing. %[1]s=EvSchema, %[2]s=RefSchema;
// $1=window interval. int4 range: [-2147483648, 2147483647].
const computeOverflowDiagSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, e.runtime_timerange, lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           COALESCE(eq.gross_machine, e.id_equipment) AS ev_src
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now()) AND e.recalc_needed
	), ev AS (
	    SELECT el.id_equipment, el.lo,
	           COALESCE(sum(CASE WHEN ee.status = 6 THEN extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi) - greatest(ee.ts_event, el.lo))) END), 0) AS running,
	           COALESCE(sum(CASE WHEN ee.status IN (5,10,11) THEN extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi) - greatest(ee.ts_event, el.lo))) END), 0) AS stopped
	      FROM eligible el
	      JOIN %[3]s.equipment_events ee ON ee.id_equipment = el.ev_src
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && el.runtime_timerange
	       AND ee.ts_event >= now() - $1::interval AND ee.ts_event < now()
	     GROUP BY el.id_equipment, el.lo
	)
	SELECT id_equipment, lo, running, stopped
	  FROM ev
	 WHERE running > 2147483647 OR stopped > 2147483647 OR running < -2147483648 OR stopped < -2147483648
	 ORDER BY greatest(abs(running), abs(stopped)) DESC
	 LIMIT 5`

// diagnoseOverflow runs computeOverflowDiagSQL and logs the offending PO(s).
// Best-effort: any error here is itself logged and swallowed — this path only
// runs after a compute failure, to add context, never to change control flow.
func diagnoseOverflow(ctx context.Context, d flows.Dest, window string, logger *slog.Logger) {
	rows, err := d.Pool.Query(ctx, fmtRD(computeOverflowDiagSQL, d), window)
	if err != nil {
		logger.Warn("overflow diagnosis query failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
		return
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var idEquipment int
		var lo time.Time
		var running, stopped float64
		if err := rows.Scan(&idEquipment, &lo, &running, &stopped); err != nil {
			continue
		}
		found = true
		logger.Error("po-runtime-compute int overflow — offending PO row",
			slog.String("dest", d.Name),
			slog.Int("id_equipment", idEquipment),
			slog.Time("runtime_lo", lo),
			slog.Float64("running_sec", running),
			slog.Float64("stopped_sec", stopped))
	}
	if !found {
		// The overflow is intermittent — the bad row may have been corrected
		// by the legacy flow or aged out of the window between the failing
		// pass and this diagnosis. Note that so the gap isn't mistaken for a
		// bug in the diagnosis itself.
		logger.Warn("overflow diagnosis found no >int4 row (already cleared/aged out)", slog.String("dest", d.Name))
	}
}

// isIntOverflow reports whether err is a Postgres numeric-value-out-of-range
// error (SQLSTATE 22003).
func isIntOverflow(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "22003"
}

// RunCompute executes one compute pass for one destination. poAvail (FU#8) gates
// the PO-grain availability write path; default false ⇒ byte-identical parity.
func RunCompute(ctx context.Context, d flows.Dest, window string, poAvail bool) (int64, error) {
	// Phase B first (see NOTE): its eligible set must predate A's clear.
	if _, err := d.Pool.Exec(ctx, fmtRD(computeEventsSQL, d), window); err != nil {
		return 0, fmt.Errorf("compute events: %w", err)
	}
	// Phase B2 (FU#8): the availability write path — MUST run before Phase A
	// clears recalc_needed (its eligible set reads recalc_needed, like Phase B).
	// Off ⇒ skipped ⇒ available_time/planned_downtime stay NULL (parity).
	if poAvail {
		if _, err := d.Pool.Exec(ctx, fmtRD(computeAvailabilitySQL, d, plannedDowntimeExpr(false)), window); err != nil {
			return 0, fmt.Errorf("compute availability: %w", err)
		}
	}
	tag, err := d.Pool.Exec(ctx, fmtRD(computeValuesSQL, d), window)
	if err != nil {
		return 0, fmt.Errorf("compute values: %w", err)
	}
	if _, err := d.Pool.Exec(ctx, fmtRD(computeReflagOpenSQL, d)); err != nil {
		return tag.RowsAffected(), fmt.Errorf("reflag open: %w", err)
	}
	if _, err := d.Pool.Exec(ctx, fmtRD(computeReflagRecentSQL, d)); err != nil {
		return tag.RowsAffected(), fmt.Errorf("reflag recent: %w", err)
	}
	return tag.RowsAffected(), nil
}

// LoopRefresh = the dispatcher (ledger: po-runtime-refresh): compute
// then recalc, ordered, drop-per-step (prod's fail-soft blocks).
func LoopRefresh(ctx context.Context, dests []flows.Dest, window string, exclEnterprises []int, poAvail bool, every time.Duration, logger *slog.Logger, obs jobs.Observer, extra func(context.Context, flows.Dest) error) {
	logger.Info("po-runtime-refresh started (P3b dispatcher: compute → recalc)", slog.Bool("po_availability", poAvail))
	jobs.Loop(ctx, jobs.Job{Name: "po-runtime-refresh", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			if _, err := RunCompute(ctx, d, window, poAvail); err != nil {
				logger.Warn("po-runtime-compute failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				// An int-overflow (SQLSTATE 22003) here is an opaque,
				// intermittent failure — dump the offending PO row so it's
				// actionable rather than a recurring mystery in the logs.
				if isIntOverflow(err) {
					diagnoseOverflow(ctx, d, window, logger)
				}
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
