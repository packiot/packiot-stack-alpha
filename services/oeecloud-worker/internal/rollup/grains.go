// grains.go — runtime-rollup-{grain} (ledger names): the cascade tier,
// ported from piot_get_equipment_runtime_{1week,1month}_production.
// Both roll up from equipment_runtime_1day (siblings, not chained).
//
// EQUIVALENCE ARGUMENT:
//   - Recipe = the recalc-flag class: eligible (flagged, 1yr window,
//     tp>1 + shared area/enterprise exclusions) LEFT JOIN day-sums,
//     zero-fill (aggregate-INTO no-GROUP-BY = always-FOUND — the
//     measured lesson), 13 metric sums verbatim, oee = net/ideal,
//     oee_a = running/(total−planned), oee_q = net/gross, flag clear,
//     current-bucket re-flag, targets pass (vl_<grain>, respecting
//     target_customized; NULL propagates — verbatim).
//   - **THE AMBER BUG (preserved)**: prod's WEEK function writes its
//     oee_p update to equipment_runtime_1MONTH (copy-paste, shipped
//     for years). Faithful port keeps it; guard test PINS it; ledger
//     carries the fix-with-consumer-signoff note. Month's own oee_p
//     correctly targets 1month.
//   - Ideal speed: NO own derivation — day-sums carry ideal_production,
//     so the tp_equipment=3 NULL-ideal LOCF fix (hour.go) is inherited.
//
// GUARDRAIL STATEMENT: UPDATEs on grain tables by (id_equipment,
// ts_value); reads 1day + reference. No PO tables.
package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// grainSpec: static matrix (never user input).
type grainSpec struct {
	Grain     string // date_trunc unit
	Table     string // target grain table
	OeePTable string // where the oee_p second-update lands (AMBER BUG: week → 1month)
	TargetCol string // production_targets column
}

var grainMatrix = []grainSpec{
	{"week", "equipment_runtime_1week", "equipment_runtime_1month", "vl_week"},
	{"month", "equipment_runtime_1month", "equipment_runtime_1month", "vl_month"},
}

const grainRollupSQL = `
	WITH eligible AS (
	    SELECT d.id_equipment, d.ts_value
	      FROM %[1]s.%[3]s d
	     WHERE d.recalc_needed
	       AND d.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	            WHERE tp_equipment > 1
	              AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))
	       AND d.ts_value >= now() - interval '1 year' AND d.ts_value <= now()
	), sums AS (
	    SELECT el.id_equipment, el.ts_value,
	           sum(ard.available_time) AS available_time,
	           sum(ard.running_time)   AS running_time,
	           sum(ard.stopped_time)   AS stopped_time,
	           sum(ard.planned_downtime) AS planned_downtime,
	           sum(ard.available_time) + sum(ard.planned_downtime) AS total_time,
	           sum(ard.ideal_production) AS ideal_production,
	           sum(ard.idle_time)      AS idle_time,
	           sum(ard.idle_starved)   AS idle_starved,
	           sum(ard.idle_blocked)   AS idle_blocked,
	           sum(ard.gross)          AS gross,
	           sum(ard.net)            AS net,
	           sum(ard.downtime)       AS downtime,
	           sum(ard.changeover_time) AS changeover_time
	      FROM eligible el
	      JOIN %[1]s.equipment_runtime_1day ard
	        ON ard.id_equipment = el.id_equipment
	       AND el.ts_value = date_trunc('%[4]s', ard.ts_value::date)::date
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.%[3]s e SET
	       available_time  = COALESCE(s.available_time, 0),
	       running_time    = COALESCE(s.running_time, 0),
	       stopped_time    = COALESCE(s.stopped_time, 0),
	       planned_downtime = COALESCE(s.planned_downtime, 0),
	       idle_time       = COALESCE(s.idle_time, 0),
	       idle_starved    = COALESCE(s.idle_starved, 0),
	       idle_blocked    = COALESCE(s.idle_blocked, 0),
	       gross           = COALESCE(s.gross, 0),
	       net             = COALESCE(s.net, 0),
	       ideal_production = COALESCE(s.ideal_production, 0),
	       downtime        = COALESCE(s.downtime, 0),
	       changeover_time = COALESCE(s.changeover_time, 0),
	       recalc_needed   = false,
	       oee   = COALESCE(s.net / NULLIF(s.ideal_production, 0), 0),
	       oee_a = COALESCE(s.running_time / NULLIF(s.total_time - s.planned_downtime, 0), 0),
	       oee_q = COALESCE(s.net / NULLIF(s.gross, 0), 0)
	  FROM eligible el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.ts_value = el.ts_value
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

// The oee_p second update — target table comes from the spec (this is
// where the week→1month amber bug lives, verbatim).
const grainOeePSQL = `
	UPDATE %[1]s.%[3]s e
	   SET oee_p = COALESCE(e.oee / NULLIF(e.oee_a * e.oee_q, 0), 0)
	  FROM (SELECT d.id_equipment, d.ts_value FROM %[1]s.%[4]s d
	         WHERE d.recalc_needed = false
	           AND d.ts_value >= now() - interval '1 year') el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

const grainReflagSQL = `
	UPDATE %[1]s.%[3]s SET recalc_needed = true
	 WHERE ts_value >= date_trunc('%[4]s', now())`

const grainTargetsSQL = `
	UPDATE %[1]s.%[3]s g
	   SET target = pt.%[5]s
	  FROM %[2]s.equipments e
	  JOIN %[2]s.enterprises e2 ON e.id_enterprise = e2.id_enterprise AND e2.active
	  LEFT JOIN %[2]s.production_targets pt ON e.id_equipment = pt.id_equipment
	 WHERE g.id_equipment = e.id_equipment
	   AND g.ts_value >= date_trunc('%[4]s', now())
	   AND g.target_customized IS NOT TRUE`

// RunGrains executes the week+month cascade for one destination.
func RunGrains(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int) error {
	for _, g := range grainMatrix {
		if _, err := d.Pool.Exec(ctx,
			fmt.Sprintf(grainRollupSQL, d.EvSchema, d.RefSchema, g.Table, g.Grain),
			exclAreas, exclEnterprises); err != nil {
			return fmt.Errorf("rollup %s: %w", g.Grain, err)
		}
		// oee_p: eligibility keyed on THIS grain's just-cleared rows,
		// written to the spec's OeePTable (amber bug for week).
		if _, err := d.Pool.Exec(ctx,
			fmt.Sprintf(grainOeePSQL, d.EvSchema, d.RefSchema, g.OeePTable, g.Table)); err != nil {
			return fmt.Errorf("oee_p %s: %w", g.Grain, err)
		}
		if _, err := d.Pool.Exec(ctx,
			fmt.Sprintf(grainReflagSQL, d.EvSchema, d.RefSchema, g.Table, g.Grain)); err != nil {
			return fmt.Errorf("reflag %s: %w", g.Grain, err)
		}
		if _, err := d.Pool.Exec(ctx,
			fmt.Sprintf(grainTargetsSQL, d.EvSchema, d.RefSchema, g.Table, g.Grain, g.TargetCol)); err != nil {
			return fmt.Errorf("targets %s: %w", g.Grain, err)
		}
	}
	return nil
}

// LoopGrains schedules runtime-rollup (the cascade tier; steps grow
// as hour/day/shift are ported).
func LoopGrains(ctx context.Context, dests []flows.Dest, exclAreas, exclEnterprises, machineLevelEnterprises []int, shiftLimit int, dqEnabled bool, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("runtime-rollup started (P3b cascade: week+month; more grains as ported)")
	jobs.Loop(ctx, jobs.Job{Name: "runtime-rollup", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			// hour first (the foundation), then day2 (sums hours),
			// then week+month — prod's intra-minute cascade order.
			if err := RunHour(ctx, d, exclAreas, exclEnterprises); err != nil {
				logger.Warn("runtime-rollup-hour failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			if err := RunDay(ctx, d, exclAreas, exclEnterprises, logger); err != nil {
				logger.Warn("runtime-rollup-day failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			if n, err := RunShift(ctx, d, exclAreas, exclEnterprises, machineLevelEnterprises, shiftLimit); err != nil {
				logger.Warn("runtime-rollup-shift failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			} else if n >= int64(shiftLimit) {
				// Batch came back full → a backlog is still draining; surface it so
				// the drain is observable (steady state logs nothing).
				logger.Info("runtime-rollup-shift draining backlog", slog.String("dest", d.Name), slog.Int64("batch", n))
			}
			if err := RunGrains(ctx, d, exclAreas, exclEnterprises); err != nil {
				logger.Warn("runtime-rollup failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			if err := RunEntityGrains(ctx, d, exclAreas); err != nil {
				logger.Warn("runtime-rollup-entity failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			// P11 andon Tier-0: DETECT + RECORD data-quality violations on the grains
			// just computed. PURE SIDE-WRITE — reads runtime rows, writes ONLY
			// data_quality_event; alters no served value. Flag-gated (DQ_ALARMS_ENABLED).
			if n, err := RunDQScan(ctx, d, dqEnabled); err != nil {
				logger.Warn("data-quality scan failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			} else if n > 0 {
				logger.Info("data-quality events recorded", slog.String("dest", d.Name), slog.Int64("upserted", n))
			}
			// Not-metered machine correction (OEE audit Defect B): line-metered
			// enterprises' tp=1 skeleton rows carry a misleading flat 0% OEE that no
			// grain computes — null them to "not metered" (NULL, not 0). Idempotent
			// and cheap in steady state. Runs LAST so it overrides any 0 left on a
			// machine row of a non-machine-level enterprise. Gate = tp=1 AND
			// enterprise NOT IN machineLevelEnterprises (the exact complement of the
			// shift grain's machine-metered inclusion) → machine-metered tenants are
			// never touched.
			if n, err := RunUnmetered(ctx, d, machineLevelEnterprises); err != nil {
				logger.Warn("runtime-rollup-unmetered failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			} else if n > 0 {
				logger.Info("runtime-rollup-unmetered nulled line-metered machine OEE", slog.String("dest", d.Name), slog.Int64("rows", n))
			}
		}
		return firstErr
	}}, logger, obs)
}
