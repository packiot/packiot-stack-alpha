// day.go — runtime-rollup-day (ledger name), ported from prod's
// piot_get_equipment_runtime_1day_production2 — THE LIVE GENERATION,
// dispatcher-verified 2026-07-04 (perform() calls production2 while
// piot_monitor_function logs the old name: the monitor lies, the
// call-site is truth). The 9KB `_production` sibling is DEAD — its
// phase-V guard cannot fire against prod's own tvp-keyed buckets.
//
// EQUIVALENCE ARGUMENT (day2 architecture — sums the HOUR grain):
//   - Eligibility: flagged day rows, 1-month window, ts_value <
//     tomorrow's per-equipment day anchor, tp>1 + exclusions (prod
//     hardcodes incl. 35=CPACK → config here; our flows keep CPACK
//     live — divergence-by-config, documented).
//   - One statement class: sums equipment_oee_hourly rows where
//     hr.ts_value_production = day.ts_value AND hr.ts_value >=
//     day.ts_value − 1 day (verbatim keys). 13 metrics + oee =
//     net/ideal + target (sum of hour targets, CASE-preserved when
//     operator-customized) + proportional_target (sum). Aggregate
//     INTO, no GROUP BY → always-FOUND → eligible LEFT JOIN
//     zero-fill (the measured recipe).
//   - Upward cascade verbatim: flags month + week (their own
//     rollups — already live — chase within the same tick).
//   - Tail: re-flag current-day rows only (this generation's
//     proportional formula is commented out — NOT ported; amber-2
//     lived in the dead generation and dies with it).
//   - Ideal speed: NO own derivation — oee = net / sum(hour rows'
//     ideal_production), so the tp_equipment=3 NULL-ideal LOCF fix
//     lives in hour.go's speed pass and this grain inherits it.
//
// GUARDRAIL: UPDATEs equipment_oee_daily (+week/month flags) by
// (id_equipment, ts_value); reads equipment_oee_hourly. No PO tables.
package rollup

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

const dayEligibleSQL = `
	CREATE TEMP TABLE day_elig ON COMMIT DROP AS
	SELECT d.id_equipment, d.ts_value, d.target_customized,
	       date_trunc('week', d.ts_value)  AS ts_week,
	       date_trunc('month', d.ts_value) AS ts_month
	  FROM %[1]s.equipment_oee_daily d
	 WHERE d.ts_value >= now() - interval '1 month'
	   AND d.ts_value < (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(d.id_equipment, now() + interval '1 day') LIMIT 1)
	   AND d.recalc_needed
	   AND d.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1
	          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))`

const dayRollupSQL = `
	WITH sums AS (
	    SELECT el.id_equipment, el.ts_value,
	           -- ADR-0037 output-invariant clamp (#576 extended): bound to [0,1].
	           GREATEST(sum(hr.net) / NULLIF(sum(hr.ideal_production), 0), 0) AS oee,
	           -- ADR-0037 C: the OEE waterfall (A×P×Q), previously unwritten at
	           -- the day grain (only composite oee). Availability = running /
	           -- planned-production-time ; Quality = net / gross ; Performance
	           -- back-solved in the UPDATE (LEGACY else-branch). When
	           -- OEE_CANONICAL_APQ is engaged, dayOeeReconcileSQL runs next and
	           -- OVERWRITES the four oee columns factors-first so oee =
	           -- oee_a·oee_p·oee_q holds by construction — matching hour/shift/
	           -- week/month. The back-solve below is kept un-gated for parity.
	           -- ADR-0037 *_oee_bounds clamp (#663): counter-only line day-rollups
	           -- can carry running > available-basis → oee_a > 1 violates the
	           -- CHECK. Availability is the ONE ratio still capped at 1 (policy
	           -- 2026-09-29, #1482); the time sums under it are raw.
	           GREATEST(LEAST(sum(hr.running_time)::float
	               / NULLIF(sum(hr.available_time), 0), 1), 0) AS oee_a,
	           GREATEST(sum(hr.net) / NULLIF(sum(hr.gross), 0), 0) AS oee_q,
	           -- STORE RAW (2026-10-13, user decision "remove the day-length cap
	           -- like P and Q"): every time metric is the plain Σ of its hour
	           -- rows. Until then available/running/stopped/downtime were capped
	           -- at the production-day length (task #59). A day sum above the day's
	           -- own wall-clock length is NOT clamped away: it is a data-quality
	           -- signal (more hour buckets attributed to the production day than
	           -- it has hours — a non-hour-aligned day_begin — or double-counted
	           -- intervals upstream) and is surfaced by data invariant
	           -- K7_day_time_gt_day_length (db/migrations/t-data-invariants-v10).
	           -- Each hour row is still bounded by its own bucket (hour.go
	           -- phase E), so the day can exceed its length only by whole
	           -- mis-attributed buckets.
	           sum(hr.available_time)   AS available_time,
	           sum(hr.running_time)     AS running_time,
	           sum(hr.stopped_time)     AS stopped_time,
	           sum(hr.planned_downtime) AS planned_downtime,
	           sum(hr.ideal_production) AS ideal_production,
	           sum(hr.target)           AS target,
	           sum(hr.gross)            AS gross,
	           sum(hr.net)              AS net,
	           sum(hr.downtime)         AS downtime,
	           sum(hr.changeover_time)  AS changeover_time,
	           sum(hr.scrap)            AS scrap,
	           avg(hr.speed)            AS speed,
	           sum(hr.proportional_target) AS proportional_target,
	           sum(hr.no_data_time)        AS no_data_time,
	           sum(hr.out_of_service_time) AS out_of_service_time
	      FROM day_elig el
	      JOIN %[1]s.equipment_oee_hourly hr
	        ON hr.id_equipment = el.id_equipment
	       AND hr.ts_value >= el.ts_value - interval '1 day'
	       AND hr.ts_value_production = el.ts_value
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_oee_daily e SET
	       oee              = COALESCE(s.oee, 0),
	       oee_a            = COALESCE(s.oee_a, 0),
	       oee_q            = COALESCE(s.oee_q, 0),
	       oee_p            = GREATEST(COALESCE(s.oee / NULLIF(s.oee_a * s.oee_q, 0), 0), 0),
	       available_time   = COALESCE(s.available_time, 0),
	       no_data_time        = COALESCE(s.no_data_time, 0),
	       out_of_service_time = COALESCE(s.out_of_service_time, 0),
	       running_time     = COALESCE(s.running_time, 0),
	       stopped_time     = COALESCE(s.stopped_time, 0),
	       planned_downtime = COALESCE(s.planned_downtime, 0),
	       ideal_production = COALESCE(s.ideal_production, 0),
	       target = CASE WHEN e.target_customized IS TRUE THEN e.target ELSE COALESCE(s.target, 0) END,
	       gross            = COALESCE(s.gross, 0),
	       net              = COALESCE(s.net, 0),
	       downtime         = COALESCE(s.downtime, 0),
	       changeover_time  = COALESCE(s.changeover_time, 0),
	       scrap            = COALESCE(s.scrap, 0),
	       speed            = COALESCE(s.speed, 0),
	       proportional_target = COALESCE(s.proportional_target, 0),
	       recalc_needed    = false
	  FROM day_elig el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.ts_value = el.ts_value
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

// dayOeeReconcileSQL — ADR-0048 §Fault-3 canonical A·P·Q for the day grain,
// mirroring grainOeeReconcileSQL (week/month) and hour/shift. Runs AFTER
// dayRollupSQL (which wrote the raw time/count columns) and overwrites the four
// oee columns factors-first: each factor is a genuine [0,1] value and oee is
// their PRODUCT as the last step, so oee == oee_a·oee_p·oee_q by construction.
// Scoped to the tick's batch (day_elig).
//
// The day grain has NO ideal_speed column (it sums 1hour, carrying only
// ideal_production), so Performance is derived from the summed ideal_production
// exactly like week/month: P = gross·available/(ideal_production·running), which
// telescopes to net/ideal_production on unclamped data.
//
// ::float CAST: running_time/available_time are INTEGER on the day table, so the
// Availability factor MUST cast or running_time/available_time is integer
// division (e.g. 3060/3600 → 0), zeroing oee_a. net=0 → oee_q = net/NULLIF(gross,0)
// → 0 (never 1), so zero-output days read oee=0, never a spurious 1.0.
const dayOeeReconcileSQL = `
	UPDATE %[1]s.equipment_oee_daily e SET
	       oee_a = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0),
	       oee_q = GREATEST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 0),
	       oee_p = GREATEST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 0),
	       oee   = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0)
	             * GREATEST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 0)
	             * GREATEST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 0)
	  FROM day_elig el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

const dayCascadeMonthSQL = `
	UPDATE %[1]s.equipment_oee_monthly m SET recalc_needed = true
	  FROM day_elig el
	 WHERE m.id_equipment = el.id_equipment AND m.ts_value = el.ts_month
	   AND m.ts_value >= el.ts_month`

const dayCascadeWeekSQL = `
	UPDATE %[1]s.equipment_oee_weekly w SET recalc_needed = true
	  FROM day_elig el
	 WHERE w.id_equipment = el.id_equipment AND w.ts_value = el.ts_week
	   AND w.ts_value >= el.ts_week`

// ADR-0036 §5A lineage stamp (T0-2). Separate additive step, NOT in
// DayStatementsForParity (parity SQL is diffed against a prod lacking these
// columns; see shift.go). Scoped to the tick's batch (day_elig). ts_value on
// the day grain is DATE → cast to timestamptz; source_watermark = LEAST(day
// bucket end, now()).
const dayStampSQL = `
	UPDATE %[1]s.equipment_oee_daily e SET
	       computed_at = now(),
	       source_watermark = LEAST(e.ts_value::timestamptz + interval '1 day', now())
	  FROM day_elig el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

const dayReflagSQL = `
	UPDATE %[1]s.equipment_oee_daily e SET recalc_needed = true
	 WHERE e.ts_value >= (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(e.id_equipment, now()) LIMIT 1)
	   AND e.ts_value <  (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(e.id_equipment, now()) LIMIT 1) + interval '1 day'
	   AND e.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1
	          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))`

// RunDay executes one day2 pass for one destination — one tx.
func RunDay(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int, ca CountersAvail, logger *slog.Logger) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	// Serialize against runtime-provision (recurring hourly deadlocks:
	// provision upserts vs rollup re-flags on the same grain tables). NON-blocking:
	// skip-and-retry if provision holds it rather than block on the pool's
	// statement_timeout. See tryRuntimeLock.
	if got, err := tryRuntimeLock(ctx, tx, d.Name); err != nil {
		return fmt.Errorf("advisory try-lock: %w", err)
	} else if !got {
		return tx.Commit(ctx)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayEligibleSQL, d.GoldSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("day eligible: %w", err)
	}
	for _, s := range daySteps(d, ca) {
		if _, err := tx.Exec(ctx, s.sql); err != nil {
			return fmt.Errorf("day %s: %w", s.name, err)
		}
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayReflagSQL, d.GoldSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("day reflag: %w", err)
	}
	return tx.Commit(ctx)
}

// daySteps is the ordered statement list RunDay executes after day_elig is built.
// Shared with the history-recompute renderer (history.go).
func daySteps(d flows.Dest, ca CountersAvail) []rollupStep {
	steps := []rollupStep{
		{"rollup", fmt.Sprintf(dayRollupSQL, d.GoldSchema)},
	}
	// ADR-0048 §Fault-3 canonical A·P·Q reconcile — overwrites the four oee
	// columns factors-first (oee = a·p·q) so the identity holds by construction,
	// exactly as hour/shift/week/month do. Inert (legacy back-solve in dayRollupSQL
	// stands) when not engaged. Runs right after rollup, before the cascades.
	if ca.engagedCanonical() {
		steps = append(steps, rollupStep{"oee-reconcile", fmt.Sprintf(dayOeeReconcileSQL, d.GoldSchema)})
	}
	steps = append(steps,
		rollupStep{"cascade-month", fmt.Sprintf(dayCascadeMonthSQL, d.GoldSchema)},
		rollupStep{"cascade-week", fmt.Sprintf(dayCascadeWeekSQL, d.GoldSchema)},
		rollupStep{"stamp", fmt.Sprintf(dayStampSQL, d.GoldSchema)},
	)
	return steps
}

// Parity accessors (single-source emission).
func DayStatementsForParity(evSchema, refSchema string) []struct{ Name, SQL string } {
	return []struct{ Name, SQL string }{
		{"eligible", fmt.Sprintf(dayEligibleSQL, evSchema, refSchema)},
		{"rollup", fmt.Sprintf(dayRollupSQL, evSchema)},
		{"cascade-month", fmt.Sprintf(dayCascadeMonthSQL, evSchema)},
		{"cascade-week", fmt.Sprintf(dayCascadeWeekSQL, evSchema)},
		{"reflag", fmt.Sprintf(dayReflagSQL, evSchema, refSchema)},
	}
}

// DayOeeReconcileSQLForParity exposes the canonical A·P·Q reconcile for the day
// grain to the golden test (proves oee == a·p·q + net=0 → oee=0). Deliberately
// NOT in DayStatementsForParity — the prod comparator has no canonical reconcile.
func DayOeeReconcileSQLForParity(evSchema string) string {
	return fmt.Sprintf(dayOeeReconcileSQL, evSchema)
}
