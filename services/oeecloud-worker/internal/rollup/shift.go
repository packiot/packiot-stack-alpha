// shift.go — runtime-rollup-shift (ledger name), ported from prod's
// piot_get_equipment_runtime_shift_production (dispatcher-verified).
//
// EQUIVALENCE ARGUMENT (the recipe, shift-keyed):
//   - Eligibility: flagged shift rows [now−30d, now] JOIN shifts
//     (cd_shift denorm) with the UNION selector: (tp>1 AND area
//     not excluded) ∪ (tp=1 AND enterprise ∈ machine-level list —
//     prod hardcodes {6} → config). Prod's exclusion list here does
//     NOT exclude 35 — shift grain includes CPACK even on prod.
//   - Phase V: ca_agg sums keyed ca.id_shift = row.id_shift AND
//     ca.ts_value_production = row.ts_value_production AND ts >=
//     row.ts_value (verbatim; the perf-critical guard prod comments
//     about). state=6-only speed. Always-FOUND → LEFT JOIN zero-fill.
//     V CLEARS the flag here (unlike hour — verbatim per body) and
//     denormalizes cd_shift. ideal_speed written from the same sums.
//   - Cascade: area_runtime_shift flagged (same ts_value).
//   - Phase E: overlaps over [ts_value, ts_end] (shift rows carry
//     ts_end), 25-day window, CONDITIONAL; oee = net/ideal with the
//     row's just-written ideal_speed; 25d update guard. E banks its
//     hits + ts_planned in a temp table for the targets pass.
//   - Targets (E-hit ∩ not-customized ∩ pt ∩ shift-hour): the shift
//     proportional formula verbatim: vl_day · (shift_size −
//     ts_planned)/(3600·24) → proportional_target only.
//   - Tail: re-flag [now−12h, now+18h] with the same UNION selector.
//
// GUARDRAIL: UPDATEs equipment_runtime_shift (+area flag) by
// (id_equipment, ts_value); reads ca_agg + events. No PO tables.
package rollup

import (
	"context"
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

const shiftEligibleSQL = `
	CREATE TEMP TABLE shift_elig ON COMMIT DROP AS
	SELECT e.id_equipment, e.ts_value, e.ts_end, e.ts_value_production,
	       e.id_shift, e.target_customized, s.cd_shift AS cd_shift2
	  FROM %[1]s.equipment_runtime_shift e
	  JOIN %[2]s.shifts s ON e.id_shift = s.id_shift
	  JOIN %[2]s.equipments eq ON e.id_equipment = eq.id_equipment
	 WHERE e.ts_value >= now() - interval '30 days' AND e.ts_value <= now()
	   AND e.recalc_needed
	   AND NOT (eq.id_enterprise = ANY($2))
	   AND e.id_equipment IN (
	       SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1 AND NOT (id_area = ANY($1))
	       UNION ALL
	       SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment = 1 AND id_enterprise = ANY($3))`

const shiftValuesSQL = `
	WITH sums AS (
	    SELECT el.id_equipment, el.ts_value,
	           sum(ca.gross_production_incr) AS gross,
	           sum(ca.net_production_incr)   AS net,
	           COALESCE(avg(ca.ideal_production_speed),
	               (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = el.id_equipment)) AS ideal_speed,
	           avg(CASE WHEN ca.state = 6 THEN ca.speed END) AS speed
	      FROM shift_elig el
	      JOIN %[1]s.ca_agg_equipment_values_1hour ca
	        ON ca.id_equipment = el.id_equipment
	       AND ca.id_shift = el.id_shift
	       AND ca.ts_value >= now() - interval '30 days'
	       AND ca.ts_value >= el.ts_value
	       AND ca.ts_value_production = el.ts_value_production
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_shift e SET
	       gross = COALESCE(s.gross, 0),
	       net   = COALESCE(s.net, 0),
	       scrap = COALESCE(s.gross - s.net, 0),
	       speed = COALESCE(s.speed, 0),
	       ideal_speed = COALESCE(s.ideal_speed, 0),
	       cd_shift = el.cd_shift2,
	       recalc_needed = false
	  FROM shift_elig el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.ts_value = el.ts_value
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value
	   AND e.ts_value >= now() - interval '30 day'`

const shiftCascadeAreaSQL = `
	UPDATE %[1]s.area_runtime_shift a SET recalc_needed = true
	  FROM shift_elig el
	  JOIN %[2]s.equipments q ON q.id_equipment = el.id_equipment
	 WHERE a.id_area = q.id_area AND a.ts_value = el.ts_value
	   AND a.ts_value >= now() - interval '30 day'`

// Phase E: conditional; banks hits + ts_planned for the targets pass.
const shiftEventsSQL = `
	CREATE TEMP TABLE shift_ev ON COMMIT DROP AS
	SELECT el.id_equipment, el.ts_value, el.ts_end, el.target_customized,
	       extract(epoch FROM (least(el.ts_end, now()) - el.ts_value)) AS ts_total,
	       COALESCE(sum(CASE WHEN ee.planned_downtime = true THEN
	           extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_end, now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_planned,
	       COALESCE(sum(CASE WHEN ee.change_over = true THEN
	           extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_end, now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_changeover,
	       COALESCE(sum(CASE WHEN ee.status = 6 THEN
	           extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_end, now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_running,
	       COALESCE(sum(CASE WHEN ee.status <> 6 THEN
	           extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_end, now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_downtime,
	       COALESCE(sum(CASE WHEN ee.status IN (5, 10, 11) THEN
	           extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_end, now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_stopped
	  FROM shift_elig el
	  JOIN %[1]s.equipment_events ee
	    ON ee.id_equipment = el.id_equipment
	   AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(el.ts_value, el.ts_end)
	   AND ee.ts_event >= now() - interval '25 days' AND ee.ts_event < now()
	 GROUP BY el.id_equipment, el.ts_value, el.ts_end, el.target_customized`

const shiftEventsUpdateSQL = `
	UPDATE %[1]s.equipment_runtime_shift e SET
	       available_time   = COALESCE(ev.ts_total - ev.ts_planned, 0),
	       running_time     = COALESCE(ev.ts_running, 0),
	       stopped_time     = COALESCE(ev.ts_stopped, 0),
	       planned_downtime = COALESCE(ev.ts_planned, 0),
	       ideal_production = COALESCE(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0),
	       downtime         = COALESCE(ev.ts_downtime, 0),
	       changeover_time  = COALESCE(ev.ts_changeover, 0),
	       recalc_needed    = false,
	       oee = COALESCE(e.net / NULLIF(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0), 0)
	  FROM shift_ev ev
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value
	   AND e.ts_value >= now() - interval '25 day'`

// Targets: the shift proportional formula, E-hit rows only.
const shiftTargetsSQL = `
	UPDATE %[1]s.equipment_runtime_shift e SET
	       proportional_target = COALESCE(pt.vl_day * ((sh.shift_size - ev.ts_planned) / (3600 * 24)), 0)
	  FROM shift_ev ev
	  JOIN %[2]s.production_targets pt ON pt.id_equipment = ev.id_equipment,
	  LATERAL piot_get_shift_hour_begin_by_equipment(ev.id_equipment, ev.ts_value) sh
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value
	   AND ev.target_customized IS NOT TRUE`

const shiftReflagSQL = `
	UPDATE %[1]s.equipment_runtime_shift e SET recalc_needed = true
	 WHERE e.ts_value >= now() - interval '12 hours'
	   AND e.ts_value < now() + interval '18 hour'
	   AND e.id_equipment IN (
	       SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1 AND NOT (id_enterprise = ANY($1))
	       UNION ALL
	       SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment = 1 AND id_enterprise = ANY($2))`

// RunShift executes one shift pass for one destination — one tx.
func RunShift(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises, machineLevelEnterprises []int) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, fmt.Sprintf(shiftEligibleSQL, d.EvSchema, d.RefSchema),
		exclAreas, exclEnterprises, machineLevelEnterprises); err != nil {
		return fmt.Errorf("shift eligible: %w", err)
	}
	steps := []struct{ name, sql string }{
		{"values", fmt.Sprintf(shiftValuesSQL, d.EvSchema, d.RefSchema)},
		{"cascade-area", fmt.Sprintf(shiftCascadeAreaSQL, d.EvSchema, d.RefSchema)},
		{"events-bank", fmt.Sprintf(shiftEventsSQL, d.EvSchema)},
		{"events-update", fmt.Sprintf(shiftEventsUpdateSQL, d.EvSchema)},
		{"targets", fmt.Sprintf(shiftTargetsSQL, d.EvSchema, d.RefSchema)},
	}
	for _, s := range steps {
		if _, err := tx.Exec(ctx, s.sql); err != nil {
			return fmt.Errorf("shift %s: %w", s.name, err)
		}
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(shiftReflagSQL, d.EvSchema, d.RefSchema),
		exclEnterprises, machineLevelEnterprises); err != nil {
		return fmt.Errorf("shift reflag: %w", err)
	}
	return tx.Commit(ctx)
}
