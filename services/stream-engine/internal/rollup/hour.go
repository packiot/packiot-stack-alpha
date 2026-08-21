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
//     avg speed + ideal — also always-FOUND (no GROUP BY) →
//     always-update zero-fill. Ideal per 1min row: bucket value,
//     LOCF from equipment_values when the bucket is NULL (prod's
//     trigger table carries LOCF'd ideal_production_speed; capture
//     :10162-10172 — the tp_equipment=3 NULL-ideal fix), then
//     equipments.production_speed — fallbacks apply to existing
//     rows only (empty hour → 0, verbatim).
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

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
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
// IDEAL-SPEED SOURCE (line-OEE fix, measured 2026-07-07 eq 51/96):
// prod's 1min tier is the trigger table agg_equipment_values_1min_t,
// whose ideal_production_speed is LOCF'd from equipment_values —
// "last non-null ideal_production_speed ≤ row ts, per equipment"
// (capture 20-oee-engine-parity.sql:10162-10172). Our flow CAgg is
// last()-in-bucket UNFILTERED → NULL in every bucket where 30701
// didn't arrive that minute. The LATERAL reproduces prod's trigger
// lookup at bucket granularity (LOCF at bucket end ≡ trigger value
// under ts-ordered inserts). Per-row fallback equipments.production_
// speed verbatim — and, verbatim, only for EXISTING 1min rows: an
// empty hour avgs to NULL → zero-fill (prod writes 0 there, never
// production_speed — aggregate-INTO is always FOUND).
const hourSpeedSQL = `
	WITH sp AS (
	    SELECT el.id_equipment, el.ts_value,
	           avg(CASE WHEN m.id_equipment IS NOT NULL THEN COALESCE(
	                    m.ideal_production_speed,
	                    locf.ideal_production_speed,
	                    q.production_speed) END) AS ideal_speed,
	           avg(m.speed) AS speed
	      FROM hour_elig el
	      LEFT JOIN %[1]s.ca_agg_equipment_values_1min m
	        ON m.id_equipment = el.id_equipment
	       AND m.ts_value >= now() - interval '65 minutes'
	       AND m.ts_value >= el.ts_value
	       AND date_trunc('hour', m.ts_value) = el.ts_value
	       AND m.ts_value >= el.ts_value - interval '1 hour'
	       AND m.ts_value <  el.ts_value + interval '1 hour'
	      LEFT JOIN LATERAL (
	           SELECT ev.ideal_production_speed
	             FROM %[1]s.equipment_values ev
	            WHERE ev.id_equipment = m.id_equipment
	              AND ev.ts_value < m.ts_value + interval '1 minute'
	              AND ev.ideal_production_speed IS NOT NULL
	            ORDER BY ev.ts_value DESC LIMIT 1
	      ) locf ON m.ideal_production_speed IS NULL
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
	       -- Physical invariant: time-in-state within an hour bucket cannot
	       -- exceed the bucket's own elapsed wall-clock (ev.ts_total). The
	       -- event sums above are per-event clipped to the hour, but OVERLAPPING
	       -- events (e.g. a line minting one running event per member machine)
	       -- sum past ts_total → a 6-machine line reads 6×3600, and eq51 ran to
	       -- 135M/hr, whose 24h day-rollup SUM overflowed int4 (SQLSTATE 22003)
	       -- and crashed the whole shadow rollup (2026-07-10 incident). LEAST is
	       -- a no-op on correct data (F1 never exceeds ts_total) and matches F1's
	       -- ≤3600 semantics; it bounds any event-layer over-mint so it can never
	       -- overflow or crash a downstream grain. Deeper line-running-time
	       -- semantics (union of intervals vs sum) tracked separately.
	       running_time     = LEAST(COALESCE(ev.ts_running, 0),    ev.ts_total),
	       stopped_time     = LEAST(COALESCE(ev.ts_stopped, 0),    ev.ts_total),
	       planned_downtime = LEAST(ev.ts_planned,                 ev.ts_total),
	       ideal_production = COALESCE(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0),
	       downtime         = LEAST(COALESCE(ev.ts_downtime, 0),   ev.ts_total),
	       changeover_time  = LEAST(COALESCE(ev.ts_changeover, 0), ev.ts_total),
	       recalc_needed    = false,
	       -- ADR-0037 output-invariant clamp (#576 extended): bound every served
	       -- OEE factor to [0,1]. Historical corrupt running_time (billions, from
	       -- the already-fixed unclosed-event class) + net>gross would otherwise
	       -- surface as oee=13918 / oee_q>1 at this grain. Clamp only the derived
	       -- oee* ratios; raw net/gross/running columns stay as the lineage truth.
	       oee = GREATEST(LEAST(COALESCE(e.net / NULLIF(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0), 0), 1), 0),
	       -- ADR-0037 C: the OEE waterfall (A×P×Q) was never written at this
	       -- grain — only the composite oee. Populate Availability + Quality
	       -- directly (running / planned-production-time ; net / gross); the
	       -- companion hourOeePSQL back-solves Performance so oee = a·p·q holds,
	       -- matching the week/month grain (grains.go) and the legacy pg engine.
	       oee_a = GREATEST(LEAST(COALESCE(LEAST(COALESCE(ev.ts_running, 0), ev.ts_total) / NULLIF(ev.ts_total - ev.ts_planned, 0), 0), 1), 0), -- ADR-0037 clamp [0,1]: line over-mint of planned_downtime makes ts_total-ts_planned<0 -> negative A -> oee_bounds CHECK abort
	       oee_q = GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0)
	  FROM ev
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value
	   AND e.ts_value >= now() - interval '6 hour'`

// Performance is the residual that closes oee = oee_a · oee_p · oee_q
// (matches grains.go grainOeePSQL + legacy 20-oee-engine-parity.sql:13282).
// Runs after the events update has persisted oee / oee_a / oee_q on the
// event-hit rows (recalc_needed just cleared). NULLIF guards a 0 A or Q.
// Also runs after the counter-only line-lead pass (line_lead.go), whose
// throughput can drive oee_p > 1; the GREATEST(LEAST(..,1),0) clamp keeps this
// write inside the *_oee_bounds invariant (#663) so the tick's CHECK holds.
const hourOeePSQL = `
	UPDATE %[1]s.equipment_runtime_1hour e
	   SET oee_p = GREATEST(LEAST(COALESCE(e.oee / NULLIF(e.oee_a * e.oee_q, 0), 0), 1), 0)
	  FROM hour_elig el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value
	   AND NOT e.recalc_needed
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

// ADR-0036 §5A lineage stamp (T0-2). Separate additive step, NOT in
// HourStatementsForParity (see shift.go's shiftStampSQL rationale — the
// parity SQL is diffed against a prod that lacks these columns). Scoped to
// the tick's batch (hour_elig). source_watermark = LEAST(hour bucket end,
// now()) — the latest event-time this hour row has visibility through.
const hourStampSQL = `
	UPDATE %[1]s.equipment_runtime_1hour e SET
	       computed_at = now(),
	       source_watermark = LEAST(e.ts_value + interval '1 hour', now())
	  FROM hour_elig el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

const hourReflagSQL = `
	UPDATE %[1]s.equipment_runtime_1hour SET recalc_needed = true
	 WHERE ts_value >= date_trunc('hour', now() - interval '2 hour')::timestamptz
	   AND ts_value <= now()`

// RunHour executes one hour pass for one destination — one tx,
// prod's phase order (V → cascades → speed → E → targets → re-flag).
// When ca.engaged() it splices the counters-only Availability fallback in
// AFTER phase E (so it targets only the state-less rows E left flagged) and
// BEFORE oee-p (so hourOeePSQL back-solves oee_p for them); when disabled the
// statement stream is byte-identical to the state-only rollup.
func RunHour(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int, ca CountersAvail) error {
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
	if _, err := tx.Exec(ctx, fmt.Sprintf(hourEligibleSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises); err != nil {
		return fmt.Errorf("hour eligible: %w", err)
	}
	steps := []rollupStep{
		{"values", fmt.Sprintf(hourValuesSQL, d.EvSchema)},
		{"cascade-day", fmt.Sprintf(hourCascadeDaySQL, d.EvSchema)},
		{"cascade-area", fmt.Sprintf(hourCascadeAreaSQL, d.EvSchema, d.RefSchema)},
		{"speed", fmt.Sprintf(hourSpeedSQL, d.EvSchema, d.RefSchema)},
		{"events", fmt.Sprintf(hourEventsSQL, d.EvSchema)},
	}
	// Counters-only Availability fallback — flag + opt-in gated, positioned
	// after events / before oee-p. Inert (not appended) when not engaged, so
	// the disabled path executes the exact original statement stream.
	if ca.engaged() {
		steps = append(steps, rollupStep{"counters-avail",
			fmt.Sprintf(hourCountsAvailSQL, d.EvSchema, pgIntArrayLiteral(ca.Equipments), ca.IdleTimeoutSec)})
	}
	// Line-from-lead derivation — flag + enterprise gated, after events / before
	// oee-p (so hourOeePSQL back-solves oee_p off the just-cleared line rows).
	// Inert (not appended) when not engaged. See line_lead.go.
	if ca.engagedLineLead() {
		steps = append(steps, rollupStep{"line-lead",
			fmt.Sprintf(hourLineLeadSQL, d.EvSchema, d.RefSchema, pgIntArrayLiteral(ca.LineLeadEnterprises), ca.IdleTimeoutSec)})
	}
	// ADR-0048 §Fault-2: availability count-floor (see shift.go). Inert when off.
	if ca.engagedFloor() {
		steps = append(steps, rollupStep{"avail-floor",
			fmt.Sprintf(hourAvailFloorSQL, d.EvSchema, pgIntArrayLiteral(ca.Equipments), ca.IdleTimeoutSec)})
	}
	// ADR-0048 §Fault-3: canonical A·P·Q reconcile replaces the legacy residual
	// when engaged; otherwise the legacy oee-p runs (byte-identical).
	if ca.engagedCanonical() {
		steps = append(steps, rollupStep{"oee-reconcile", fmt.Sprintf(hourOeeReconcileSQL, d.EvSchema)})
	} else {
		steps = append(steps, rollupStep{"oee-p", fmt.Sprintf(hourOeePSQL, d.EvSchema)})
	}
	steps = append(steps,
		rollupStep{"targets", fmt.Sprintf(hourTargetsSQL, d.EvSchema, d.RefSchema)},
		rollupStep{"stamp", fmt.Sprintf(hourStampSQL, d.EvSchema)},
		rollupStep{"reflag", fmt.Sprintf(hourReflagSQL, d.EvSchema)},
	)
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
		{"oee-p", fmt.Sprintf(hourOeePSQL, evSchema)},
		{"targets", fmt.Sprintf(hourTargetsSQL, evSchema, refSchema)},
		{"reflag", fmt.Sprintf(hourReflagSQL, evSchema)},
	}
}
