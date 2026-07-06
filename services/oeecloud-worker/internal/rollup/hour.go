// hour.go — runtime-rollup-hour (ledger name), ported from prod's
// piot_get_equipment_runtime_1hour_production (DISPATCHER-VERIFIED
// live generation, 2026-07-04). The cascade's foundation grain.
//
// EQUIVALENCE ARGUMENT:
//   - Window: flagged hour buckets in [now()−65min, now()].
//   - Phase V (ca_agg sums → gross/net/scrap): always-FOUND class →
//     eligible LEFT JOIN zero-fill. CRUCIALLY sets recalc_needed=TRUE
//     (verbatim!) — only the events phase clears the flag.
//   - Cascades verbatim: flags the equipment's DAY row (tvp-keyed via
//     day-begin fn) and the area's HOUR row.
//   - Speed pass from the 1min tier (flows: native ca_agg_1min):
//     avg speed + ideal (fallback equipments.production_speed) —
//     also always-FOUND (no GROUP BY) → always-update zero-fill.
//   - Phase E (event overlaps, [ts,+1h)): GROUP BY → CONDITIONAL
//     inner join; sets recalc_needed=FALSE (the only clear);
//     oee = net/ideal, ideal=((total−planned)/60)·ideal_speed;
//     guard ts_value >= now()−6h verbatim.
//   - Targets NESTED inside phase E's if-found (verbatim semantics):
//     only event-hit rows get proportional_target = vl_day/24 (target
//     column itself commented out in prod). Set-form: driven off rows
//     the events phase just cleared (V re-flags, only E clears —
//     cleared ∩ eligible == event-hit, exactly).
//   - Tail: re-flag hours in [trunc(now()−2h), now()] verbatim.
//   - Exclusion lists (prod hardcodes incl. 35=CPACK) → config; our
//     flows keep CPACK live (divergence-by-config, documented).
//
// GUARDRAIL: UPDATEs equipment_runtime_1hour (+day/area flag
// cascades) by (id_equipment, ts_value). No PO tables.
package rollup

import (
	"context"
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

const hourEligibleSQL = `
	CREATE TEMP TABLE hour_elig ON COMMIT DROP AS
	SELECT h.id_equipment, h.ts_value, h.target_customized
	  FROM %[1]s.equipment_runtime_1hour h
	 WHERE h.ts_value >= now() - interval '65 minutes' AND h.ts_value <= now()
	   AND h.recalc_needed
	   AND h.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1
	          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))`

// Phase V: always-FOUND → always-update; keeps the flag TRUE (verbatim).
const hourValuesSQL = `
	WITH sums AS (
	    SELECT el.id_equipment, el.ts_value,
	           sum(ca.gross_production_incr) AS gross,
	           sum(ca.net_production_incr)   AS net
	      FROM hour_elig el
	      JOIN %[1]s.ca_agg_equipment_values_1hour ca
	        ON ca.id_equipment = el.id_equipment
	       AND ca.ts_value >= now() - interval '65 minutes'
	       AND ca.ts_value = el.ts_value
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_1hour e SET
	       gross = COALESCE(s.gross, 0),
	       net   = COALESCE(s.net, 0),
	       scrap = COALESCE(s.gross - s.net, 0),
	       recalc_needed = true
	  FROM hour_elig el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.ts_value = el.ts_value
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value
	   AND e.ts_value >= now() - interval '65 minutes'`

const hourCascadeDaySQL = `
	UPDATE %[1]s.equipment_runtime_1day d SET recalc_needed = true
	  FROM hour_elig el
	 WHERE d.id_equipment = el.id_equipment
	   AND d.ts_value = (SELECT ts_value_production FROM piot_get_day_begin_by_equipment(el.id_equipment, el.ts_value) LIMIT 1)`

const hourCascadeAreaSQL = `
	UPDATE %[1]s.area_runtime_1hour a SET recalc_needed = true
	  FROM hour_elig el
	  JOIN %[2]s.equipments q ON q.id_equipment = el.id_equipment
	 WHERE a.id_area = q.id_area AND a.ts_value = el.ts_value`

// Speed pass from the 1min tier — always-FOUND → always-update.
const hourSpeedSQL = `
	WITH sp AS (
	    SELECT el.id_equipment, el.ts_value,
	           avg(CASE WHEN m.ideal_production_speed IS NOT NULL
	                    THEN m.ideal_production_speed ELSE q.production_speed END) AS ideal_speed,
	           avg(m.speed) AS speed
	      FROM hour_elig el
	      LEFT JOIN %[1]s.ca_agg_equipment_values_1min m
	        ON m.id_equipment = el.id_equipment
	       AND m.ts_value >= now() - interval '65 minutes'
	       AND m.ts_value >= el.ts_value
	       AND date_trunc('hour', m.ts_value) = el.ts_value
	       AND m.ts_value >= el.ts_value - interval '1 hour'
	       AND m.ts_value <  el.ts_value + interval '1 hour'
	      LEFT JOIN %[2]s.equipments q ON q.id_equipment = el.id_equipment
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_1hour e SET
	       speed       = COALESCE(sp.speed, 0),
	       ideal_speed = COALESCE(sp.ideal_speed, 0)
	  FROM sp
	 WHERE e.id_equipment = sp.id_equipment AND e.ts_value = sp.ts_value`

// Phase E: CONDITIONAL; the ONLY flag clear. ideal_speed read from
// the row (just written by the speed pass — prod reads r_speed).
const hourEventsSQL = `
	WITH ev AS (
	    SELECT el.id_equipment, el.ts_value,
	           extract(epoch FROM (least(el.ts_value + interval '1 hour', now()) - el.ts_value)) AS ts_total,
	           COALESCE(sum(CASE WHEN ee.planned_downtime = true THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_value + interval '1 hour', now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_planned,
	           COALESCE(sum(CASE WHEN ee.change_over = true THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_value + interval '1 hour', now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_changeover,
	           COALESCE(sum(CASE WHEN ee.status = 6 THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_value + interval '1 hour', now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_running,
	           COALESCE(sum(CASE WHEN ee.status <> 6 THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_value + interval '1 hour', now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_downtime,
	           COALESCE(sum(CASE WHEN ee.status IN (5, 10, 11) THEN
	               extract(epoch FROM (least(COALESCE(ee.ts_end, now()), COALESCE(el.ts_value + interval '1 hour', now())) - greatest(ee.ts_event, el.ts_value))) END), 0) AS ts_stopped
	      FROM hour_elig el
	      JOIN %[1]s.equipment_events ee
	        ON ee.id_equipment = el.id_equipment
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(el.ts_value, el.ts_value + interval '1 hour')
	       AND ee.ts_event >= now() - interval '10 days' AND ee.ts_event < now()
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_1hour e SET
	       available_time   = COALESCE(ev.ts_total - ev.ts_planned, 0),
	       running_time     = COALESCE(ev.ts_running, 0),
	       stopped_time     = COALESCE(ev.ts_stopped, 0),
	       planned_downtime = ev.ts_planned,
	       ideal_production = COALESCE(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0),
	       downtime         = COALESCE(ev.ts_downtime, 0),
	       changeover_time  = COALESCE(ev.ts_changeover, 0),
	       recalc_needed    = false,
	       oee = COALESCE(e.net / NULLIF(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0), 0)
	  FROM ev
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value
	   AND e.ts_value >= now() - interval '6 hour'`

// Targets: event-hit rows only (cleared ∩ eligible — see argument).
const hourTargetsSQL = `
	UPDATE %[1]s.equipment_runtime_1hour e SET
	       proportional_target = COALESCE(pt.vl_day::float / 24, 0)
	  FROM hour_elig el
	  JOIN %[2]s.production_targets pt ON pt.id_equipment = el.id_equipment
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value
	   AND NOT e.recalc_needed
	   AND el.target_customized IS NOT TRUE
	   AND EXISTS (SELECT 1 FROM piot_get_shift_hour_begin_by_equipment(el.id_equipment, el.ts_value))`

const hourReflagSQL = `
	UPDATE %[1]s.equipment_runtime_1hour SET recalc_needed = true
	 WHERE ts_value >= date_trunc('hour', now() - interval '2 hour')::timestamptz
	   AND ts_value <= now()`

// RunHour executes one hour pass for one destination — one tx,
// prod's phase order (V → cascades → speed → E → targets → re-flag).
func RunHour(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int) error {
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
	if _, err := tx.Exec(ctx, fmt.Sprintf(hourEligibleSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("hour eligible: %w", err)
	}
	steps := []struct{ name, sql string }{
		{"values", fmt.Sprintf(hourValuesSQL, d.EvSchema)},
		{"cascade-day", fmt.Sprintf(hourCascadeDaySQL, d.EvSchema)},
		{"cascade-area", fmt.Sprintf(hourCascadeAreaSQL, d.EvSchema, d.RefSchema)},
		{"speed", fmt.Sprintf(hourSpeedSQL, d.EvSchema, d.RefSchema)},
		{"events", fmt.Sprintf(hourEventsSQL, d.EvSchema)},
		{"targets", fmt.Sprintf(hourTargetsSQL, d.EvSchema, d.RefSchema)},
		{"reflag", fmt.Sprintf(hourReflagSQL, d.EvSchema)},
	}
	for _, s := range steps {
		if _, err := tx.Exec(ctx, s.sql); err != nil {
			return fmt.Errorf("hour %s: %w", s.name, err)
		}
	}
	return tx.Commit(ctx)
}

// Parity accessors (single-source emission).
func HourStatementsForParity(evSchema, refSchema string) []struct{ Name, SQL string } {
	return []struct{ Name, SQL string }{
		{"eligible", fmt.Sprintf(hourEligibleSQL, evSchema, refSchema)},
		{"values", fmt.Sprintf(hourValuesSQL, evSchema)},
		{"cascade-day", fmt.Sprintf(hourCascadeDaySQL, evSchema)},
		{"cascade-area", fmt.Sprintf(hourCascadeAreaSQL, evSchema, refSchema)},
		{"speed", fmt.Sprintf(hourSpeedSQL, evSchema, refSchema)},
		{"events", fmt.Sprintf(hourEventsSQL, evSchema)},
		{"targets", fmt.Sprintf(hourTargetsSQL, evSchema, refSchema)},
		{"reflag", fmt.Sprintf(hourReflagSQL, evSchema)},
	}
}
