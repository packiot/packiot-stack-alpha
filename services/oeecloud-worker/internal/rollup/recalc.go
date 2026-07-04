// Package rollup — ADR-0014 P3b: the runtime roll-up engine.
// recalc.go = po-runtime-recalc (ledger name), ported from prod's
// piot_get_equipment_production_order_runtime_final: the
// recalc_needed CONSUMER — closes the loop that pocontrol opens
// (lifecycle writes SET the flag; this pass consumes it).
//
// REFACTOR WITH PROOF OF EQUIVALENCE (user ask): prod's per-PO PL/pgSQL
// loop collapses into ONE set-based UPDATE:
//   - the loop's per-site SET LOCAL TIME ZONE is vestigial for the
//     math EXCEPT one bounded edge (user review caught the probe):
//     now() - '1 month' under a DST zone can shift the month-old
//     window boundary by ≤1h vs our session-tz evaluation. Documented
//     BOUNDED DIVERGENCE: affects only ranges straddling that 30-day-
//     old edge; the consistent boundary is arguably more correct.
//   - prod's "if found" guard == the join against grouped sums (POs
//     without runtime rows stay untouched, flag intact — identical).
//   - prod computed oee_performance in a second UPDATE from the
//     just-stored columns; we compute it inline from the SAME
//     expressions — identical values, one statement.
//   - tx boundary: prod ran the whole pass in one tx (dispatcher
//     commits after the call) — a single statement preserves exactly
//     that all-or-nothing pass semantics.
//   - declared-but-unused loop RECORDs (r_oeea, r_labels, i) = dead
//     vestige, not ported.
//
// Config (no-hardcoded-ids): window (prod '1 month') and excluded
// enterprises (prod: id_enterprise != 6 — enterprise 6's recalc is
// owned by its sync chain) are parameters, defaults preserve prod.
//
// GUARDRAIL STATEMENT: updates production_orders columns (OEE fields,
// recalc_needed, last_update) by PK join; reads
// production_orders_runtime. No inserts, no range writes — the
// EXCLUDE/partial-unique guardrails are not in play.
package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// The formulas are prod-verbatim: quality = net/gross;
// oee = net / (((total-planned)/60) * ideal_speed);
// availability = running/available; performance = oee/(avail*quality).
const recalcSQL = `
	WITH sums AS (
	    SELECT ca.id_production_order,
	           sum(ca.gross_production)  AS gross,
	           sum(ca.net_production)    AS net,
	           avg(ca.speed)             AS speed,
	           sum(ca.available_time)    AS avail,
	           sum(ca.available_time) + sum(ca.planned_downtime) AS total,
	           sum(ca.running_time)      AS run,
	           sum(ca.stopped_time)      AS stop,
	           sum(ca.planned_downtime)  AS planned
	      FROM %[1]s.production_orders_runtime ca
	      JOIN %[1]s.production_orders e USING (id_production_order)
	     WHERE e.ts_start >= now() - $1::interval
	       AND e.recalc_needed AND e.status > 1
	       AND NOT (e.id_enterprise = ANY($2))
	       AND ca.runtime_timerange && tstzrange(now() - $1::interval, now())
	     GROUP BY ca.id_production_order
	)
	UPDATE %[1]s.production_orders e SET
	       gross_production = COALESCE(s.gross, 0),
	       net_production   = COALESCE(s.net, 0),
	       oee_quality      = COALESCE(s.net / NULLIF(s.gross, 0), 0),
	       speed            = COALESCE(s.speed, 0),
	       available_time   = COALESCE(s.avail, 0),
	       running_time     = COALESCE(s.run, 0),
	       stopped_time     = COALESCE(s.stop, 0),
	       planned_downtime = COALESCE(s.planned, 0),
	       oee = COALESCE(s.net / NULLIF(((s.total - s.planned) / 60.0) *
	             NULLIF(COALESCE(e.ideal_production_speed,
	                 (SELECT q.production_speed FROM %[2]s.equipments q
	                   WHERE q.id_equipment = e.id_equipment)), 0), 0), 0),
	       oee_availability = COALESCE(s.run / NULLIF(s.avail, 0), 0),
	       oee_performance  = COALESCE(
	             COALESCE(s.net / NULLIF(((s.total - s.planned) / 60.0) *
	                 NULLIF(COALESCE(e.ideal_production_speed,
	                     (SELECT q.production_speed FROM %[2]s.equipments q
	                       WHERE q.id_equipment = e.id_equipment)), 0), 0), 0)
	             / NULLIF(COALESCE(s.run / NULLIF(s.avail, 0), 0) *
	                      COALESCE(s.net / NULLIF(s.gross, 0), 0), 0), 0),
	       recalc_needed = false,
	       last_update   = now()
	  FROM sums s
	 WHERE e.id_production_order = s.id_production_order`

// The self-re-enqueue (verbatim): running POs recalc every pass;
// finished ones keep refreshing for 48h (late operator edits).
const reflagRunningSQL = `
	UPDATE %[1]s.production_orders SET recalc_needed = true
	 WHERE status = 2 AND recalc_needed = false`

const reflagRecentSQL = `
	UPDATE %[1]s.production_orders SET recalc_needed = true
	 WHERE status = 3 AND ts_start >= now() - interval '48 hours'
	   AND recalc_needed = false`

// RunRecalc executes one pass for one destination.
func RunRecalc(ctx context.Context, d flows.Dest, window string, exclEnterprises []int) (int64, error) {
	tag, err := d.Pool.Exec(ctx, fmt.Sprintf(recalcSQL, d.EvSchema, d.RefSchema), window, exclEnterprises)
	if err != nil {
		return 0, fmt.Errorf("recalc: %w", err)
	}
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(reflagRunningSQL, d.EvSchema)); err != nil {
		return tag.RowsAffected(), fmt.Errorf("reflag running: %w", err)
	}
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(reflagRecentSQL, d.EvSchema)); err != nil {
		return tag.RowsAffected(), fmt.Errorf("reflag recent: %w", err)
	}
	return tag.RowsAffected(), nil
}

// LoopRecalc schedules po-runtime-recalc on the jobs runner.
func LoopRecalc(ctx context.Context, dests []flows.Dest, window string, exclEnterprises []int, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("po-runtime-recalc started (P3b — the recalc_needed consumer)")
	jobs.Loop(ctx, jobs.Job{Name: "po-runtime-recalc", Every: every, Run: func(ctx context.Context) error {
		return jobs.RunPerDest(ctx, dests, "po-runtime-recalc", logger, func(ctx context.Context, d flows.Dest) (int64, error) {
			return RunRecalc(ctx, d, window, exclEnterprises)
		})
	}}, logger, obs)
}

// Parity accessors — the harness emits the SAME constants it executes
// (single-source guarantee for differential runs).
func RecalcSQLForParity() string     { return recalcSQL }
func ReflagRunningForParity() string { return reflagRunningSQL }
func ReflagRecentForParity() string  { return reflagRecentSQL }
