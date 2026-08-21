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
//     denormalizes cd_shift. ideal_speed written from the same sums;
//     per-bucket LOCF from equipment_values fills the flow CAgg's
//     NULL ideal_production_speed (prod's tier carries the trigger
//     table's LOCF'd value — see shiftValuesSQL comment; the
//     tp_equipment=3 NULL-ideal fix, shared with hour.go).
//   - Cascade: area_runtime_shift flagged (same ts_value).
//   - Phase E: overlaps over [ts_value, ts_end] (shift rows carry
//     ts_end), 25-day window, CONDITIONAL; oee = net/ideal with the
//     row's just-written ideal_speed; 25d update guard. E banks its
//     hits + ts_planned in a temp table for the targets pass.
//   - Targets (E-hit ∩ not-customized ∩ pt ∩ shift-hour): the shift
//     proportional formula, ELAPSED-prorated (ADR-0029 D5 / #80):
//     vl_day · (ts_total − ts_planned)/(3600·24) → proportional_target
//     only. ts_total is elapsed-capped-at-ts_end, so a LIVE shift scales
//     with elapsed and a COMPLETED shift settles at the full target.
//     tp-agnostic, single writer. (Was full-shift: shift_size − ts_planned.)
//   - Tail: re-flag [now−12h, now+18h] with the same UNION selector.
//
// GUARDRAIL: UPDATEs equipment_runtime_shift (+area flag) by
// (id_equipment, ts_value); reads ca_agg + events. No PO tables.
package rollup

import (
	"context"
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// BOUNDED per-tick (%[3]d = LIMIT). The eligible set spans a 30-day window and,
// because shift rows are partitioned by (id_shift × ts_value_production), can hold
// thousands of flagged rows after any burst (an incident, a poison purge, a manual
// reflag). RunShift processes shift_elig in ONE transaction, so an unbounded set
// under I/O pressure (e.g. concurrent cagg materialization) blows the tick's
// context deadline and rolls back WHOLESALE — committing nothing, draining nothing,
// forever (observed 2026-07-11: F2=5517 / F3=2076 stuck; #437's running_time cap
// never reaching the stale rows). LIMIT makes every tick commit a bounded slice, so
// the backlog drains monotonically over ticks (same discipline as backfill.go).
//
// ORDER BY ts_value ASC (oldest-first): the recent tail is re-flagged EVERY tick by
// shiftReflagSQL, so newest-first would let that fresh reflag perpetually crowd out
// the old backlog and it would never drain. Oldest-first drains the backlog to zero;
// once drained, only the small recent set remains and each tick clears it promptly.
// LIMIT is pure row-selection — it never changes HOW a selected row is computed, so
// parity with prod's per-row math is preserved (ShiftStatementsForParity passes an
// effectively-unbounded limit to compare the full set).
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
	        WHERE tp_equipment = 1 AND id_enterprise = ANY($3))
	 ORDER BY e.ts_value ASC
	 LIMIT %[3]d`

// IDEAL-SPEED SOURCE (line-OEE fix, same mechanism as hour.go):
// prod's ca_agg_equipment_values_1hour rows inherit the trigger
// table's LOCF'd ideal_production_speed (equipment_values last
// non-null ≤ row ts; capture 20-oee-engine-parity.sql:10162-10172,
// carried through 22-agg-views.sql:248 GROUP BY). Our flow CAgg is
// last()-in-bucket unfiltered → NULL wherever 30701 didn't arrive
// in-bucket → tp_equipment=3 rows fell to production_speed (NULL
// for lines) → ideal_speed 0 → oee 0. The LATERAL restores prod's
// value at bucket-end granularity; avg-then-fallback shape verbatim.
const shiftValuesSQL = `
	WITH sums AS (
	    SELECT el.id_equipment, el.ts_value,
	           sum(ca.gross_production_incr) AS gross,
	           sum(ca.net_production_incr)   AS net,
	           COALESCE(avg(COALESCE(ca.ideal_production_speed, locf.ideal_production_speed)),
	               (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = el.id_equipment)) AS ideal_speed,
	           avg(CASE WHEN ca.state = 6 THEN ca.speed END) AS speed
	      FROM shift_elig el
	      JOIN %[1]s.ca_agg_equipment_values_1hour ca
	        ON ca.id_equipment = el.id_equipment
	       AND ca.id_shift = el.id_shift
	       AND ca.ts_value >= now() - interval '30 days'
	       AND ca.ts_value >= el.ts_value
	       AND ca.ts_value_production = el.ts_value_production
	      LEFT JOIN LATERAL (
	           SELECT ev.ideal_production_speed
	             FROM %[1]s.equipment_values ev
	            WHERE ev.id_equipment = ca.id_equipment
	              AND ev.ts_value < ca.ts_value + interval '1 hour'
	              AND ev.ideal_production_speed IS NOT NULL
	            ORDER BY ev.ts_value DESC LIMIT 1
	      ) locf ON ca.ideal_production_speed IS NULL
	     GROUP BY el.id_equipment, el.ts_value
	)
	UPDATE %[1]s.equipment_runtime_shift e SET
	       gross = COALESCE(s.gross, 0),
	       net   = COALESCE(s.net, 0),
	       scrap = COALESCE(s.gross - s.net, 0),
	       speed = COALESCE(s.speed, 0),
	       -- LINE ideal_speed fix (parity with prod). Prod computes
	       -- ideal_speed = COALESCE(avg(ca.ideal), equipments.production_speed, 0)
	       -- as ONE aggregate, so a row with NO matching ca_agg buckets still
	       -- falls to production_speed. Here the production_speed fallback lives
	       -- INSIDE the sums CTE — but when the ca_agg join yields no sums row at
	       -- all (common for tp=3 lines whose 30701 never lands in-bucket and whose
	       -- shift row has no matching cagg bucket), s.ideal_speed is NULL and the
	       -- old COALESCE(s.ideal_speed, 0) defaulted to 0 — diverging from prod,
	       -- which returns production_speed (measured 2026-07-11: eq81 F1=58/F3=0).
	       -- Restore prod's semantics by falling to production_speed at the OUTER
	       -- level too. No-op when the sums row exists (s.ideal_speed already carries
	       -- the inner fallback); only lifts the no-cagg-match rows off 0.
	       ideal_speed = COALESCE(s.ideal_speed,
	           (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = el.id_equipment), 0),
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
	       -- Same physical invariant as the hour grain (see hour.go): time-in-state
	       -- within a shift bucket cannot exceed the shift's own elapsed wall-clock
	       -- (ev.ts_total). Overlapping events (a line minting one running event
	       -- per member machine) make the per-event-clipped sum exceed ts_total —
	       -- observed live as a 6.7e9 shift running_time on F3 (line-event
	       -- over-count). LEAST is a no-op on correct data and matches F1's ≤shift
	       -- semantics; it bounds any over-mint from inflating this grain.
	       running_time     = LEAST(COALESCE(ev.ts_running, 0),    ev.ts_total),
	       stopped_time     = LEAST(COALESCE(ev.ts_stopped, 0),    ev.ts_total),
	       planned_downtime = LEAST(COALESCE(ev.ts_planned, 0),    ev.ts_total),
	       ideal_production = COALESCE(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0),
	       downtime         = LEAST(COALESCE(ev.ts_downtime, 0),   ev.ts_total),
	       changeover_time  = LEAST(COALESCE(ev.ts_changeover, 0), ev.ts_total),
	       recalc_needed    = false,
	       oee = GREATEST(LEAST(COALESCE(e.net / NULLIF(((ev.ts_total - ev.ts_planned) / 60.0) * NULLIF(e.ideal_speed, 0), 0), 0), 1), 0), -- ADR-0037 clamp [0,1]
	       -- ADR-0037 C: write the OEE waterfall (A×P×Q), not just composite oee.
	       -- Availability = running / planned-production-time ; Quality = net /
	       -- gross ; Performance back-solved by shiftOeePSQL so oee = a·p·q
	       -- (same shape as grains.go / legacy pg engine). Was: A/P/Q all 0.
	       oee_a = GREATEST(LEAST(COALESCE(LEAST(COALESCE(ev.ts_running, 0), ev.ts_total) / NULLIF(ev.ts_total - ev.ts_planned, 0), 0), 1), 0), -- ADR-0037 clamp [0,1]: line over-mint of planned_downtime makes ts_total-ts_planned<0 -> negative A -> oee_bounds CHECK abort
	       oee_q = GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0)
	  FROM shift_ev ev
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value
	   AND e.ts_value >= now() - interval '25 day'`

// Performance residual — closes oee = oee_a · oee_p · oee_q on the event-hit
// shift rows the events update just persisted (see hourOeePSQL for rationale).
const shiftOeePSQL = `
	UPDATE %[1]s.equipment_runtime_shift e
	   SET oee_p = GREATEST(LEAST(COALESCE(e.oee / NULLIF(e.oee_a * e.oee_q, 0), 0), 1), 0)
	  FROM shift_ev ev
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value
	   AND e.ts_value >= now() - interval '25 day'`

// Targets: the shift proportional formula, E-hit rows only.
//
// ELAPSED PRORATION (ADR-0029 D5 / #80 — restores the backend's
// prorate-per-elapsed assumption that front4 #80 consumes). The former
// write used sh.shift_size (the FULL scheduled shift duration), so a
// LIVE shift's proportional_target already showed the whole-shift target
// two hours in — every line/machine shift card read "behind" all shift.
// The fix: prorate by ELAPSED scheduled-productive time, tp-agnostic,
// exactly like the legacy base machine fn post-#80
// (20-oee-engine-parity.sql: target · (least(now(),ts_end)−ts_value)/shift_size).
//
//	proportional_target = vl_day · (ev.ts_total − ev.ts_planned) / 86400
//
//	- ev.ts_total = extract(epoch (least(ts_end, now()) − ts_value)) —
//	  wall-clock elapsed, CAPPED at the shift end. For a COMPLETED (past)
//	  shift ts_total = ts_end − ts_value = shift_size, so the row settles
//	  at the full/final target (elapsed == full). Only the LIVE shift
//	  prorates; past shifts keep their final target. No tp branch.
//	- (ts_total − ts_planned) is the shift's ELAPSED scheduled-productive
//	  time (identical expression to available_time above). Denominator
//	  convention: SCHEDULED-PRODUCTIVE — already-consumed planned
//	  downtime is subtracted in the numerator basis exactly as the
//	  full-shift form subtracted it (vl_day is a per-DAY rate over 86400s),
//	  so a scheduled break pauses target growth instead of overstating it.
//	- SINGLE writer (one UPDATE of this column per row) — do NOT add a
//	  post-pass overwrite; that is the #456 two-writer double-count class.
//	- The LATERAL shift-hour lookup is RETAINED purely as the "shift-hour
//	  found" guard (legacy's `if found`): its shift_size is intentionally
//	  no longer referenced now that proration is elapsed-based.
const shiftTargetsSQL = `
	UPDATE %[1]s.equipment_runtime_shift e SET
	       proportional_target = COALESCE(pt.vl_day * ((ev.ts_total - ev.ts_planned) / (3600 * 24)), 0)
	  FROM shift_ev ev
	  JOIN %[2]s.production_targets pt ON pt.id_equipment = ev.id_equipment,
	  LATERAL piot_get_shift_hour_begin_by_equipment(ev.id_equipment, ev.ts_value) sh
	 WHERE e.id_equipment = ev.id_equipment AND e.ts_value = ev.ts_value
	   AND ev.target_customized IS NOT TRUE`

// ADR-0036 §5A lineage stamp (T0-2). SEPARATE, additive step — deliberately
// NOT part of ShiftStatementsForParity: the parity accessors are diffed
// against PROD (F2), which does not carry these columns until the gated
// prod-apply, so folding the stamp into the value SQL would break the
// comparator. Runs inside RunShift's tx, scoped to the just-processed batch
// (shift_elig). computed_at = compute wall-clock; source_watermark = the
// latest event-time the row has visibility through (LEAST(bucket_end, now));
// for a live shift the two coincide, for a replayed old shift computed_at is
// recent while source_watermark settles at ts_end — the auditable distinction.
const shiftStampSQL = `
	UPDATE %[1]s.equipment_runtime_shift e SET
	       computed_at = now(),
	       source_watermark = LEAST(COALESCE(e.ts_end, e.ts_value + interval '1 day'), now())
	  FROM shift_elig el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

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

// RunShift executes one shift pass for one destination — one tx. It recomputes up
// to `limit` of the OLDEST flagged shift rows and returns how many it processed
// (0 = backlog empty). LoopGrains ticks every 60s, so a backlog drains `limit` rows
// per tick until empty; the recent tail (shiftReflagSQL) then keeps it at zero.
func RunShift(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises, machineLevelEnterprises []int, limit int, ca CountersAvail) (int64, error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	// Serialize against runtime-provision (recurring hourly deadlocks:
	// provision upserts vs rollup re-flags on the same grain tables). NON-blocking:
	// if provision holds the lock (it can run minutes under I/O pressure), skip this
	// tick and retry — the flagged rows stay queued — rather than block and die on
	// the pool's statement_timeout. See tryRuntimeLock.
	if got, err := tryRuntimeLock(ctx, tx, d.Name); err != nil {
		return 0, fmt.Errorf("advisory try-lock: %w", err)
	} else if !got {
		return 0, tx.Commit(ctx)
	}
	tag, err := tx.Exec(ctx, fmt.Sprintf(shiftEligibleSQL, d.EvSchema, d.RefSchema, limit),
		exclAreas, exclEnterprises, machineLevelEnterprises)
	if err != nil {
		return 0, fmt.Errorf("shift eligible: %w", err)
	}
	n := tag.RowsAffected()
	// Drive the value/event passes from this bounded batch via index seeks rather
	// than seq-scanning the big ca_agg/events tables (same rationale as
	// backfill.go: an un-analyzed temp table gives the planner no row estimate).
	if _, err := tx.Exec(ctx, `CREATE INDEX ON shift_elig (id_equipment, ts_value)`); err != nil {
		return 0, fmt.Errorf("shift elig index: %w", err)
	}
	if _, err := tx.Exec(ctx, `ANALYZE shift_elig`); err != nil {
		return 0, fmt.Errorf("shift elig analyze: %w", err)
	}
	steps := []rollupStep{
		{"values", fmt.Sprintf(shiftValuesSQL, d.EvSchema, d.RefSchema)},
		{"cascade-area", fmt.Sprintf(shiftCascadeAreaSQL, d.EvSchema, d.RefSchema)},
		{"events-bank", fmt.Sprintf(shiftEventsSQL, d.EvSchema)},
		{"events-update", fmt.Sprintf(shiftEventsUpdateSQL, d.EvSchema)},
	}
	// Counters-only Availability fallback — flag + opt-in gated, positioned
	// after events-update (shift_ev exists → the NOT-EXISTS state-less anti-
	// join resolves) and before oee-p. Inert (not appended) when not engaged.
	if ca.engaged() {
		steps = append(steps, rollupStep{"counters-avail",
			fmt.Sprintf(shiftCountsAvailSQL, d.EvSchema, pgIntArrayLiteral(ca.Equipments), ca.IdleTimeoutSec)})
	}
	// Line-from-lead derivation — flag + enterprise gated, same region as the
	// counters-avail fallback (before oee-p; shift back-solves oee_p inline).
	// Inert (not appended) when not engaged. See line_lead.go.
	if ca.engagedLineLead() {
		steps = append(steps, rollupStep{"line-lead",
			fmt.Sprintf(shiftLineLeadSQL, d.EvSchema, d.RefSchema, pgIntArrayLiteral(ca.LineLeadEnterprises), ca.IdleTimeoutSec)})
	}
	// ADR-0048 §Fault-2: availability count-floor — raise running_time to the
	// count-active time for opted-in equipment where the state stream had gaps.
	// After every state/counter running writer, before the oee finalize so the
	// reconcile/oee-p reads the healed running. Inert when not engaged.
	if ca.engagedFloor() {
		steps = append(steps, rollupStep{"avail-floor",
			fmt.Sprintf(shiftAvailFloorSQL, d.EvSchema, pgIntArrayLiteral(ca.Equipments), ca.IdleTimeoutSec)})
	}
	// ADR-0048 §Fault-3: canonical A·P·Q reconcile (whole batch) REPLACES the
	// legacy event-row-scoped oee-p residual when engaged; otherwise the legacy
	// residual runs (byte-identical). Either way targets + stamp follow.
	if ca.engagedCanonical() {
		steps = append(steps, rollupStep{"oee-reconcile", fmt.Sprintf(shiftOeeReconcileSQL, d.EvSchema)})
	} else {
		steps = append(steps, rollupStep{"oee-p", fmt.Sprintf(shiftOeePSQL, d.EvSchema)})
	}
	steps = append(steps,
		rollupStep{"targets", fmt.Sprintf(shiftTargetsSQL, d.EvSchema, d.RefSchema)},
		rollupStep{"stamp", fmt.Sprintf(shiftStampSQL, d.EvSchema)},
	)
	for _, s := range steps {
		if _, err := tx.Exec(ctx, s.sql); err != nil {
			return 0, fmt.Errorf("shift %s: %w", s.name, err)
		}
	}
	// Reflag runs EVERY tick (even when the batch was empty) so the recent tail
	// stays live — it is a small [now−12h, now+18h] window, independent of the
	// bounded batch above.
	if _, err := tx.Exec(ctx, fmt.Sprintf(shiftReflagSQL, d.EvSchema, d.RefSchema),
		exclEnterprises, machineLevelEnterprises); err != nil {
		return 0, fmt.Errorf("shift reflag: %w", err)
	}
	return n, tx.Commit(ctx)
}

// parityShiftLimit keeps the parity emission effectively unbounded: the port
// comparison must select the whole eligible set, not a per-tick slice. The LIMIT
// is a runtime row-selection knob and changes no per-row computation, so an
// unbounded parity run and a bounded production run compute identical values for
// any row they share.
const parityShiftLimit = 1 << 31 // ~2.1e9 rows — never binds in parity

// Parity accessors (single-source emission).
func ShiftStatementsForParity(evSchema, refSchema string) []struct{ Name, SQL string } {
	return []struct{ Name, SQL string }{
		{"eligible", fmt.Sprintf(shiftEligibleSQL, evSchema, refSchema, parityShiftLimit)},
		{"values", fmt.Sprintf(shiftValuesSQL, evSchema, refSchema)},
		{"cascade-area", fmt.Sprintf(shiftCascadeAreaSQL, evSchema, refSchema)},
		{"events-bank", fmt.Sprintf(shiftEventsSQL, evSchema)},
		{"events-update", fmt.Sprintf(shiftEventsUpdateSQL, evSchema)},
		{"oee-p", fmt.Sprintf(shiftOeePSQL, evSchema)},
		{"targets", fmt.Sprintf(shiftTargetsSQL, evSchema, refSchema)},
		{"reflag", fmt.Sprintf(shiftReflagSQL, evSchema, refSchema)},
	}
}
