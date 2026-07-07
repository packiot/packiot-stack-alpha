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
//   - One statement class: sums equipment_runtime_1hour rows where
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
// GUARDRAIL: UPDATEs equipment_runtime_1day (+week/month flags) by
// (id_equipment, ts_value); reads equipment_runtime_1hour. No PO tables.
package rollup

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

const dayEligibleSQL = `
	CREATE TEMP TABLE day_elig ON COMMIT DROP AS
	SELECT d.id_equipment, d.ts_value, d.target_customized,
	       date_trunc('week', d.ts_value)  AS ts_week,
	       date_trunc('month', d.ts_value) AS ts_month
	  FROM %[1]s.equipment_runtime_1day d
	 WHERE d.ts_value >= now() - interval '1 month'
	   AND d.ts_value < (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(d.id_equipment, now() + interval '1 day') LIMIT 1)
	   AND d.recalc_needed
	   AND d.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1
	          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))`

const dayRollupSQL = `
	WITH sums AS (
	    SELECT el.id_equipment, el.ts_value,
	           sum(hr.net) / NULLIF(sum(hr.ideal_production), 0) AS oee,
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
	           sum(hr.proportional_target) AS proportional_target
	      FROM day_elig el
	      JOIN %[1]s.equipment_runtime_1hour hr
	        ON hr.id_equipment = el.id_equipment
	       AND hr.ts_value >= el.ts_value - interval '1 day'
	       AND hr.ts_value_production = el.ts_value
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_1day e SET
	       oee              = COALESCE(s.oee, 0),
	       available_time   = COALESCE(s.available_time, 0),
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

const dayCascadeMonthSQL = `
	UPDATE %[1]s.equipment_runtime_1month m SET recalc_needed = true
	  FROM day_elig el
	 WHERE m.id_equipment = el.id_equipment AND m.ts_value = el.ts_month
	   AND m.ts_value >= el.ts_month`

const dayCascadeWeekSQL = `
	UPDATE %[1]s.equipment_runtime_1week w SET recalc_needed = true
	  FROM day_elig el
	 WHERE w.id_equipment = el.id_equipment AND w.ts_value = el.ts_week
	   AND w.ts_value >= el.ts_week`

const dayReflagSQL = `
	UPDATE %[1]s.equipment_runtime_1day e SET recalc_needed = true
	 WHERE e.ts_value >= (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(e.id_equipment, now()) LIMIT 1)
	   AND e.ts_value <  (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(e.id_equipment, now()) LIMIT 1) + interval '1 day'
	   AND e.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1
	          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))`

// RunDay executes one day2 pass for one destination — one tx.
func RunDay(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int, logger *slog.Logger) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	// Serialize against runtime-provision (recurring hourly deadlocks:
	// provision upserts vs rollup re-flags on the same grain tables).
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, d.Name+":runtime"); err != nil {
		return fmt.Errorf("advisory lock: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayEligibleSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("day eligible: %w", err)
	}
	steps := []struct{ name, sql string }{
		{"rollup", fmt.Sprintf(dayRollupSQL, d.EvSchema)},
		{"cascade-month", fmt.Sprintf(dayCascadeMonthSQL, d.EvSchema)},
		{"cascade-week", fmt.Sprintf(dayCascadeWeekSQL, d.EvSchema)},
	}
	for _, s := range steps {
		if _, err := tx.Exec(ctx, s.sql); err != nil {
			return fmt.Errorf("day %s: %w", s.name, err)
		}
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayReflagSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("day reflag: %w", err)
	}
	return tx.Commit(ctx)
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
