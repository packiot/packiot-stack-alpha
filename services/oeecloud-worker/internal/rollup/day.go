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
	       date_trunc('month', d.ts_value) AS ts_month,
	       -- TRUE production-day length in seconds = next day's anchor
	       -- minus this day's anchor, sourced from the SAME day-boundary
	       -- function the eligibility window below already uses. NOT
	       -- hardcoded 86400: America/Sao_Paulo DST makes legit days of
	       -- 90000 (fall-back) and 82800 (spring-forward) seconds. Adding
	       -- the CALENDAR interval '1 day' lands on the next per-equipment
	       -- anchor regardless of DST, so the epoch diff is the real
	       -- wall-clock day length. Feeds the LEAST() ceiling in the sums
	       -- CTE of dayRollupSQL (task #59 — defensive over-mint clamp).
	       --
	       -- MUST subtract the two timestamptz ANCHORS (the fn's ts_value
	       -- column), NOT the date-typed ts_value_production label and NOT
	       -- d.ts_value directly: equipment_runtime_1day.ts_value is DATE
	       -- (production-date key), and the fn's ts_value_production is also
	       -- DATE, so (ts_value_production - d.ts_value) is (date - date) =
	       -- INTEGER (a day count), and extract(epoch FROM integer) does
	       -- not exist -> SQLSTATE 42883 (task #93). The day_begin offset
	       -- cancels in anchor(D+1) − anchor(D), leaving the true DST-aware
	       -- wall-clock length as an interval; extract(epoch …) yields secs.
	       extract(epoch FROM (
	           (SELECT ts_value FROM piot_get_day_begin_by_equipment(d.id_equipment, d.ts_value + interval '1 day') LIMIT 1)
	         - (SELECT ts_value FROM piot_get_day_begin_by_equipment(d.id_equipment, d.ts_value) LIMIT 1)
	       )) AS day_len_s
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
	           -- ADR-0037 output-invariant clamp (#576 extended): bound to [0,1].
	           LEAST(sum(hr.net) / NULLIF(sum(hr.ideal_production), 0), 1) AS oee,
	           -- ADR-0037 C: the OEE waterfall (A×P×Q), previously unwritten at
	           -- the day grain (only composite oee). Availability = running /
	           -- planned-production-time ; Quality = net / gross ; Performance
	           -- back-solved in the UPDATE so oee = a·p·q — matching the
	           -- week/month grain (grains.go) and legacy pg engine.
	           LEAST(sum(hr.running_time), el.day_len_s)
	               / NULLIF(LEAST(sum(hr.available_time), el.day_len_s), 0) AS oee_a,
	           LEAST(sum(hr.net) / NULLIF(sum(hr.gross), 0), 1) AS oee_q,
	           -- Physical invariant: a production-day's time-in-state cannot
	           -- exceed the day's own wall-clock length (el.day_len_s). The
	           -- HOUR grain is :00-aligned, but a non-hour-aligned site
	           -- day_begin (e.g. 02:10) makes a 24h production-day straddle
	           -- 25 whole hour buckets, so the naked sum reaches 25×3600 =
	           -- 90000s — impossible (> 86400). LEAST is a no-op on correct
	           -- data and matches the same ceiling hour.go/shift.go already
	           -- apply on their grains (see hour.go phase E). day_len_s is
	           -- the TRUE per-equipment length, so DST-legit 90000/82800s
	           -- days are preserved (NOT clamped to 86400).
	           --
	           -- DEFENSIVE BOUND ONLY (task #59): this caps the impossible
	           -- over-counted day, but the ADJACENT under-counted day (the
	           -- boundary hour double-books one day and shorts the other —
	           -- 90000+82800=172800=48h) STAYS under. The structural fix for
	           -- the boundary-hour misattribution ripples into prod stored
	           -- procs (piot_create_equipment_runtime_1hour) and is out of
	           -- scope here — tracked for a follow-up design call.
	           LEAST(sum(hr.available_time), el.day_len_s) AS available_time,
	           LEAST(sum(hr.running_time),   el.day_len_s) AS running_time,
	           LEAST(sum(hr.stopped_time),   el.day_len_s) AS stopped_time,
	           sum(hr.planned_downtime) AS planned_downtime,
	           sum(hr.ideal_production) AS ideal_production,
	           sum(hr.target)           AS target,
	           sum(hr.gross)            AS gross,
	           sum(hr.net)              AS net,
	           LEAST(sum(hr.downtime),   el.day_len_s) AS downtime,
	           sum(hr.changeover_time)  AS changeover_time,
	           sum(hr.scrap)            AS scrap,
	           avg(hr.speed)            AS speed,
	           sum(hr.proportional_target) AS proportional_target
	      FROM day_elig el
	      JOIN %[1]s.equipment_runtime_1hour hr
	        ON hr.id_equipment = el.id_equipment
	       AND hr.ts_value >= el.ts_value - interval '1 day'
	       AND hr.ts_value_production = el.ts_value
	     GROUP BY el.id_equipment, el.ts_value, el.day_len_s
	)
	UPDATE %[1]s.equipment_runtime_1day e SET
	       oee              = COALESCE(s.oee, 0),
	       oee_a            = COALESCE(s.oee_a, 0),
	       oee_q            = COALESCE(s.oee_q, 0),
	       oee_p            = LEAST(COALESCE(s.oee / NULLIF(s.oee_a * s.oee_q, 0), 0), 1),
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

// ADR-0036 §5A lineage stamp (T0-2). Separate additive step, NOT in
// DayStatementsForParity (parity SQL is diffed against a prod lacking these
// columns; see shift.go). Scoped to the tick's batch (day_elig). ts_value on
// the day grain is DATE → cast to timestamptz; source_watermark = LEAST(day
// bucket end, now()).
const dayStampSQL = `
	UPDATE %[1]s.equipment_runtime_1day e SET
	       computed_at = now(),
	       source_watermark = LEAST(e.ts_value::timestamptz + interval '1 day', now())
	  FROM day_elig el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

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
	// provision upserts vs rollup re-flags on the same grain tables). NON-blocking:
	// skip-and-retry if provision holds it rather than block on the pool's
	// statement_timeout. See tryRuntimeLock.
	if got, err := tryRuntimeLock(ctx, tx, d.Name); err != nil {
		return fmt.Errorf("advisory try-lock: %w", err)
	} else if !got {
		return tx.Commit(ctx)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayEligibleSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("day eligible: %w", err)
	}
	steps := []struct{ name, sql string }{
		{"rollup", fmt.Sprintf(dayRollupSQL, d.EvSchema)},
		{"cascade-month", fmt.Sprintf(dayCascadeMonthSQL, d.EvSchema)},
		{"cascade-week", fmt.Sprintf(dayCascadeWeekSQL, d.EvSchema)},
		{"stamp", fmt.Sprintf(dayStampSQL, d.EvSchema)},
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
