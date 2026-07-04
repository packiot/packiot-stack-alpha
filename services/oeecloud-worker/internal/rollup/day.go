// day.go — runtime-rollup-day (ledger name), ported from prod's
// piot_get_equipment_runtime_1day_production: the richest grain.
//
// EQUIVALENCE ARGUMENT:
//   - ONE TX PER PASS: the plpgsql body is a single transaction; the
//     port mirrors it (temp eligibility snapshot ON COMMIT DROP, then
//     phases in prod's order). This also solves the ordering knot:
//     phase V clears recalc_needed, phase E must see the SAME
//     eligible set AND V's fresh `net` — snapshot gives both.
//   - Phase V (ca_agg sums → gross/net/scrap/speed): ALWAYS-update
//     class (aggregate INTO, no GROUP BY) → eligible LEFT JOIN +
//     zero-fill. speed = avg ONLY WHERE state=6 (Eduardo 2024-02-29,
//     verbatim). Update guarded ts_value >= ts_start (verbatim).
//   - UPWARD CASCADE (the self-propagation): processed days mark
//     their month AND week dirty — verbatim.
//   - Phase E (event overlaps): GROUP BY present → CONDITIONAL
//     (inner join; no-event rows keep prior values). Window =
//     [ts_value_real, +1day) where ts_value_real is the tz-anchored
//     day begin. oee = net/ideal with ideal=((total−planned)/60)·
//     ideal_speed; prod's duplicate available_time re-assignment
//     collapsed (same value twice — outcome identical).
//   - Targets: vl_day + proportional_target, only when a shift-hour
//     exists and not operator-customized — verbatim.
//   - AMBER BUG #2, INTENT-RESTORED (documented divergence): prod's
//     current-day proportional_target references the LOOP VARIABLE
//     AFTER the loop (last row's day-anchor applied to all rows;
//     errors when loop empty). Port computes it PER ROW — the
//     unambiguous intent; identical when all equipments share a
//     site/tz (CPACK case), strictly defined otherwise.
//   - Exclusions (tp>1, areas, enterprises) → shared config.
//
// GUARDRAIL: UPDATEs on equipment_runtime_1day/(1week/1month flags)
// by (id_equipment, ts_value); reads ca_agg + events + reference.
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
	       (SELECT ts_value FROM piot_get_day_begin_by_equipment(d.id_equipment, d.ts_value + interval '12 hour') LIMIT 1) AS ts_start,
	       (SELECT ts_value FROM piot_get_day_begin_by_equipment(d.id_equipment,
	            (d.ts_value::date + (interval '1 second' * piot_get_day_begin_offset_by_equipment(d.id_equipment)))::timestamptz) LIMIT 1) AS ts_real
	  FROM %[1]s.equipment_runtime_1day d
	 WHERE d.ts_value >= now() - interval '1 month'
	   AND d.ts_value < (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(d.id_equipment, now() + interval '1 day') LIMIT 1)
	   AND d.recalc_needed
	   AND d.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1
	          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))`

const dayValuesSQL = `
	WITH sums AS (
	    SELECT el.id_equipment, el.ts_value,
	           sum(ca.gross_production_incr) AS gross,
	           sum(ca.net_production_incr)   AS net,
	           sum(ca.gross_production_incr) - sum(ca.net_production_incr) AS scrap,
	           COALESCE(avg(ca.ideal_production_speed),
	               (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = el.id_equipment)) AS ideal_speed,
	           avg(CASE WHEN ca.state = 6 THEN ca.speed END) AS speed
	      FROM day_elig el
	      JOIN %[1]s.ca_agg_equipment_values_1hour ca
	        ON ca.id_equipment = el.id_equipment
	       AND ca.ts_value_production >= now() - interval '1 month'
	       AND ca.ts_value >= el.ts_start
	       AND ca.ts_value_production = el.ts_value
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_1day e SET
	       gross = COALESCE(s.gross, 0),
	       net   = COALESCE(s.net, 0),
	       scrap = COALESCE(s.scrap, 0),
	       speed = COALESCE(s.speed, 0),
	       recalc_needed = false
	  FROM day_elig el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.ts_value = el.ts_value
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value
	   AND e.ts_value >= el.ts_start`

const dayCascadeMonthSQL = `
	UPDATE %[1]s.equipment_runtime_1month m SET recalc_needed = true
	  FROM day_elig el
	 WHERE m.id_equipment = el.id_equipment AND m.ts_value = date_trunc('month', el.ts_value)`

const dayCascadeWeekSQL = `
	UPDATE %[1]s.equipment_runtime_1week w SET recalc_needed = true
	  FROM day_elig el
	 WHERE w.id_equipment = el.id_equipment AND w.ts_value = date_trunc('week', el.ts_value)`

// Phase E: CONDITIONAL (inner join — prod's GROUP BY FOUND semantics).
// ideal_speed re-derived identically to phase V (same expressions on
// the same snapshot → same value).
const dayEventsSQL = `
	WITH ev AS (
	    SELECT el.id_equipment, el.ts_value,
	           extract(epoch FROM (least(el.ts_real + interval '1 day', now()) - el.ts_real)) AS ts_total,
	           COALESCE(sum(CASE WHEN ee.planned_downtime = true THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_real + interval '1 day', now())) - greatest(ee.ts_event, el.ts_real))) END), 0) AS ts_planned,
	           COALESCE(sum(CASE WHEN ee.change_over = true THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_real + interval '1 day', now())) - greatest(ee.ts_event, el.ts_real))) END), 0) AS ts_changeover,
	           COALESCE(sum(CASE WHEN ee.status = 6 THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_real + interval '1 day', now())) - greatest(ee.ts_event, el.ts_real))) END), 0) AS ts_running,
	           COALESCE(sum(CASE WHEN ee.status <> 6 THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_real + interval '1 day', now())) - greatest(ee.ts_event, el.ts_real))) END), 0) AS ts_downtime,
	           COALESCE(sum(CASE WHEN ee.status IN (5, 10, 11) THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_real + interval '1 day', now())) - greatest(ee.ts_event, el.ts_real))) END), 0) AS ts_stopped
	      FROM day_elig el
	      JOIN %[1]s.equipment_events ee
	        ON ee.id_equipment = el.id_equipment
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(el.ts_real, el.ts_real + interval '1 day')
	       AND ee.ts_event >= now() - interval '1 month' AND ee.ts_event < now()
	     GROUP BY el.id_equipment, el.ts_value, el.ts_real
	), ideal AS (
	    SELECT el.id_equipment, el.ts_value,
	           COALESCE(avg(ca.ideal_production_speed),
	               (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = el.id_equipment)) AS ideal_speed
	      FROM day_elig el
	      LEFT JOIN %[1]s.ca_agg_equipment_values_1hour ca
	        ON ca.id_equipment = el.id_equipment
	       AND ca.ts_value_production >= now() - interval '1 month'
	       AND ca.ts_value >= el.ts_start
	       AND ca.ts_value_production = el.ts_value
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_1day e SET
	       available_time   = COALESCE(ev.ts_total - ev.ts_planned, 0),
	       running_time     = COALESCE(ev.ts_running, 0),
	       stopped_time     = COALESCE(ev.ts_stopped, 0),
	       planned_downtime = COALESCE(ev.ts_planned, 0),
	       ideal_production = COALESCE(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(i.ideal_speed, 0), 0),
	       downtime         = COALESCE(ev.ts_downtime, 0),
	       changeover_time  = COALESCE(ev.ts_changeover, 0),
	       recalc_needed    = false,
	       oee = COALESCE(e.net / NULLIF(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(i.ideal_speed, 0), 0), 0)
	  FROM ev
	  JOIN ideal i ON i.id_equipment = ev.id_equipment AND i.ts_value = ev.ts_value
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value`

// Targets: only non-customized rows with an existing shift-hour.
const dayTargetsSQL = `
	UPDATE %[1]s.equipment_runtime_1day e SET
	       target = COALESCE(pt.vl_day, 0),
	       proportional_target = COALESCE(pt.vl_day, 0)
	  FROM day_elig el
	  JOIN %[2]s.production_targets pt ON pt.id_equipment = el.id_equipment
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value
	   AND el.target_customized IS NOT TRUE
	   AND EXISTS (SELECT 1 FROM piot_get_shift_hour_begin_by_equipment(el.id_equipment, el.ts_value))`

// Current-day re-flag + proportional. AMBER BUG #2 intent-restored:
// per-row day anchor (prod leaked the last loop row's).
const dayReflagSQL = `
	UPDATE %[1]s.equipment_runtime_1day e SET
	       recalc_needed = true,
	       proportional_target = e.target * (
	           extract(epoch FROM (now() - (SELECT ts_value FROM piot_get_day_begin_by_equipment(e.id_equipment, e.ts_value) LIMIT 1)))
	           / 3600 / 24)
	 WHERE e.ts_value >= (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(e.id_equipment, now()) LIMIT 1)
	   AND e.ts_value <  (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(e.id_equipment, now()) LIMIT 1) + interval '1 day'`

// RunDay executes one day pass for one destination — ONE TX, prod's
// phase order (V → cascade → E → targets → re-flag).
func RunDay(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int, logger *slog.Logger) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayEligibleSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("day eligible: %w", err)
	}
	steps := []struct{ name, sql string }{
		{"values", fmt.Sprintf(dayValuesSQL, d.EvSchema, d.RefSchema)},
		{"cascade-month", fmt.Sprintf(dayCascadeMonthSQL, d.EvSchema)},
		{"cascade-week", fmt.Sprintf(dayCascadeWeekSQL, d.EvSchema)},
		{"events", fmt.Sprintf(dayEventsSQL, d.EvSchema, d.RefSchema)},
		{"targets", fmt.Sprintf(dayTargetsSQL, d.EvSchema, d.RefSchema)},
		{"reflag", fmt.Sprintf(dayReflagSQL, d.EvSchema)},
	}
	for _, s := range steps {
		if _, err := tx.Exec(ctx, s.sql); err != nil {
			return fmt.Errorf("day %s: %w", s.name, err)
		}
	}
	return tx.Commit(ctx)
}
