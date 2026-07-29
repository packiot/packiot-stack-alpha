// availability.go — the counters-only AVAILABILITY fallback for state-less
// Modbus machines. Follow-up to PR #591 (counters-only OEE), which made a
// speed-sensorless machine compute PERFORMANCE from counts against a
// configured rated speed. Availability, though, is derived from
// StateCurrent/downtime events (running_time / planned_time), so a machine
// that is counters-only AND emits no state signal has no availability basis:
// its equipment_runtime rows keep running_time = 0 → oee_a = 0.
//
// THE INFERENCE (idle-timeout sessionization). We reconstruct running-vs-
// stopped from COUNT ACTIVITY in the 1-min continuous aggregate. Order the
// productive minutes (gross_production_incr > 0) within a bucket; a "session"
// (island, in gaps-and-islands terms) is a maximal run of productive minutes
// whose inter-minute gap never exceeds the idle timeout. Each session is
// credited from its first productive minute through (last productive minute +
// idle timeout), clipped to the bucket end — the grace we grant after the
// final count before declaring the machine stopped. Gaps longer than the
// timeout fall OUTSIDE every session and count as stopped, so an idle stretch
// drives Availability below 1. Availability = Σ session-seconds / bucket
// wall-clock (planned_downtime is 0 by construction — a state-less bucket has
// no events, hence no planned downtime).
//
// AUTO-ENGAGE (two conditions, both required, evaluated per bucket):
//   1. The id_equipment is opted in (CountersAvail.Equipments) — the rollup
//      analog of #591's per-equipment COUNTERS_ONLY_IDEAL_RATES opt-in; a
//      state-driven machine is never touched even by accident.
//   2. The bucket carried NO state events. Detected differently per grain
//      because the two flows manage recalc_needed differently:
//        - HOUR: phase V keeps recalc_needed=true, phase E clears it only on
//          event-hit rows → still-flagged-after-E ⟺ no events (see hour.go).
//        - SHIFT: phase V CLEARS recalc_needed for every row, so the flag is
//          NOT a no-events signal; instead the events phase banks event-hit
//          rows in the shift_ev temp table, so NOT EXISTS shift_ev ⟺ no
//          events (see shift.go).
//
// FLAG-OFF PARITY: the fallback is a SEPARATE pass appended to RunHour /
// RunShift only when engaged() (and never added to the *ForParity accessors
// the prod comparator diffs). When disabled the executed statement stream is
// byte-identical to the state-only rollup, so the golden fixtures and the
// F2↔F3 identity comparator are untouched.
//
// SINGLE WRITER (the #456 two-writer lesson): the fallback and the events
// phase write disjoint row sets (event-hit vs no-event), so every
// running_time/available_time/oee_a cell has exactly one writer. For hour the
// fallback runs BEFORE hourOeePSQL and leaves oee_p to it (hourOeePSQL drives
// off hour_elig ∩ cleared). For shift, shiftOeePSQL is scoped to shift_ev
// (event rows) and never sees the fallback rows, so the shift fallback
// back-solves oee_p inline.
package rollup

import (
	"strconv"
	"strings"
)

// CountersAvail configures the counters-only Availability fallback (see
// config.go CountersOnlyAvail*). The zero value is disabled: RunHour /
// RunShift append no fallback pass, so the rollup is byte-identical to the
// state-only path.
type CountersAvail struct {
	Enabled        bool
	Equipments     []int // opted-in id_equipment (empty → inert even if Enabled)
	IdleTimeoutSec int   // grace seconds after the last count before "stopped"
}

// engaged reports whether the fallback pass should run this tick. Requires the
// master flag, at least one opted-in equipment, and a positive idle timeout
// (a 0 timeout would make every gap a session boundary and every lone count a
// zero-length session — nonsensical, so treat it as off).
func (c CountersAvail) engaged() bool {
	return c.Enabled && len(c.Equipments) > 0 && c.IdleTimeoutSec > 0
}

// pgIntArrayLiteral renders a []int as a Postgres bigint[] literal, e.g.
// {91,92,93}. The ids come from config (config.CSVInts of an env var), never
// from user input, so inlining them keeps the fallback pass param-free like
// the surrounding rollup steps without an injection surface.
func pgIntArrayLiteral(ids []int) string {
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = strconv.Itoa(id)
	}
	return "'{" + strings.Join(parts, ",") + "}'::bigint[]"
}

// rollupStep is one named SQL statement in a grain pass. Named so hour.go and
// shift.go can splice the (conditional) counters-availability step into their
// statement slices without repeating an anonymous struct type.
type rollupStep struct {
	name, sql string
}

// hourCountsAvailSQL — the hour-grain fallback. %[1]s = EvSchema, %[2]s =
// opted-in equipment array literal, %[3]d = idle timeout (seconds). Targets
// ONLY opted-in rows the events phase left flagged (recalc_needed still true
// ⇒ no state events). Leaves oee_p to hourOeePSQL (runs next, drives off the
// just-cleared rows). See file header for the inference model.
const hourCountsAvailSQL = `
	WITH bounds AS (
	    SELECT el.id_equipment, el.ts_value,
	           LEAST(el.ts_value + interval '1 hour', now()) AS bend,
	           extract(epoch FROM (LEAST(el.ts_value + interval '1 hour', now()) - el.ts_value)) AS ts_total
	      FROM hour_elig el
	     WHERE el.id_equipment = ANY(%[2]s)
	), prod_min AS (
	    SELECT b.id_equipment, b.ts_value, b.bend, m.ts_value AS mts,
	           extract(epoch FROM (m.ts_value - lag(m.ts_value) OVER (
	               PARTITION BY b.id_equipment, b.ts_value ORDER BY m.ts_value))) AS gap
	      FROM bounds b
	      JOIN %[1]s.ca_agg_equipment_values_1min m
	        ON m.id_equipment = b.id_equipment
	       AND m.ts_value >= b.ts_value
	       AND m.ts_value <  b.bend
	       AND m.gross_production_incr > 0
	), islanded AS (
	    SELECT id_equipment, ts_value, bend, mts,
	           sum(CASE WHEN gap IS NULL OR gap > %[3]d THEN 1 ELSE 0 END)
	               OVER (PARTITION BY id_equipment, ts_value ORDER BY mts) AS island
	      FROM prod_min
	), sessions AS (
	    SELECT id_equipment, ts_value,
	           extract(epoch FROM (LEAST(max(mts) + make_interval(secs => %[3]d), min(bend)) - min(mts))) AS span
	      FROM islanded
	     GROUP BY id_equipment, ts_value, island
	), active AS (
	    SELECT id_equipment, ts_value, sum(span) AS raw_running
	      FROM sessions
	     GROUP BY id_equipment, ts_value
	)
	UPDATE %[1]s.equipment_runtime_1hour e SET
	       available_time   = b.ts_total,
	       running_time     = LEAST(COALESCE(a.raw_running, 0), b.ts_total),
	       stopped_time     = b.ts_total - LEAST(COALESCE(a.raw_running, 0), b.ts_total),
	       planned_downtime = 0,
	       downtime         = b.ts_total - LEAST(COALESCE(a.raw_running, 0), b.ts_total),
	       changeover_time  = 0,
	       ideal_production = COALESCE((b.ts_total / 60.0) * NULLIF(e.ideal_speed, 0), 0),
	       recalc_needed    = false,
	       oee   = LEAST(COALESCE(e.net / NULLIF((b.ts_total / 60.0) * NULLIF(e.ideal_speed, 0), 0), 0), 1), -- ADR-0037 clamp
	       oee_a = COALESCE(LEAST(COALESCE(a.raw_running, 0), b.ts_total) / NULLIF(b.ts_total, 0), 0),
	       oee_q = LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1)
	  FROM bounds b
	  LEFT JOIN active a ON a.id_equipment = b.id_equipment AND a.ts_value = b.ts_value
	 WHERE e.id_equipment = b.id_equipment AND e.ts_value = b.ts_value
	   AND e.recalc_needed = true
	   AND e.ts_value >= now() - interval '6 hour'`

// shiftCountsAvailSQL — the shift-grain fallback. %[1]s = EvSchema, %[2]s =
// opted-in equipment array literal, %[3]d = idle timeout (seconds). Detects
// state-less buckets via NOT EXISTS shift_ev (the event-hit temp table) since
// the shift phase V clears recalc_needed for every row. Bounded to recent
// buckets (2 days) where the 1-min cagg is guaranteed materialized, so an
// absence of count activity reliably means idle rather than aged-out minute
// data; this window comfortably covers every live-reflagged shift
// ([now-12h, now+18h]). Back-solves oee_p inline because shiftOeePSQL is
// scoped to shift_ev and never reaches these rows.
const shiftCountsAvailSQL = `
	WITH bounds AS (
	    SELECT el.id_equipment, el.ts_value,
	           LEAST(el.ts_end, now()) AS bend,
	           extract(epoch FROM (LEAST(el.ts_end, now()) - el.ts_value)) AS ts_total
	      FROM shift_elig el
	     WHERE el.id_equipment = ANY(%[2]s)
	       AND el.ts_value >= now() - interval '2 days'
	       AND NOT EXISTS (SELECT 1 FROM shift_ev ev
	                        WHERE ev.id_equipment = el.id_equipment AND ev.ts_value = el.ts_value)
	), prod_min AS (
	    SELECT b.id_equipment, b.ts_value, b.bend, m.ts_value AS mts,
	           extract(epoch FROM (m.ts_value - lag(m.ts_value) OVER (
	               PARTITION BY b.id_equipment, b.ts_value ORDER BY m.ts_value))) AS gap
	      FROM bounds b
	      JOIN %[1]s.ca_agg_equipment_values_1min m
	        ON m.id_equipment = b.id_equipment
	       AND m.ts_value >= b.ts_value
	       AND m.ts_value <  b.bend
	       AND m.gross_production_incr > 0
	), islanded AS (
	    SELECT id_equipment, ts_value, bend, mts,
	           sum(CASE WHEN gap IS NULL OR gap > %[3]d THEN 1 ELSE 0 END)
	               OVER (PARTITION BY id_equipment, ts_value ORDER BY mts) AS island
	      FROM prod_min
	), sessions AS (
	    SELECT id_equipment, ts_value,
	           extract(epoch FROM (LEAST(max(mts) + make_interval(secs => %[3]d), min(bend)) - min(mts))) AS span
	      FROM islanded
	     GROUP BY id_equipment, ts_value, island
	), active AS (
	    SELECT id_equipment, ts_value, sum(span) AS raw_running
	      FROM sessions
	     GROUP BY id_equipment, ts_value
	)
	UPDATE %[1]s.equipment_runtime_shift e SET
	       available_time   = b.ts_total,
	       running_time     = LEAST(COALESCE(a.raw_running, 0), b.ts_total),
	       stopped_time     = b.ts_total - LEAST(COALESCE(a.raw_running, 0), b.ts_total),
	       planned_downtime = 0,
	       downtime         = b.ts_total - LEAST(COALESCE(a.raw_running, 0), b.ts_total),
	       changeover_time  = 0,
	       ideal_production = COALESCE((b.ts_total / 60.0) * NULLIF(e.ideal_speed, 0), 0),
	       recalc_needed    = false,
	       oee   = LEAST(COALESCE(e.net / NULLIF((b.ts_total / 60.0) * NULLIF(e.ideal_speed, 0), 0), 0), 1), -- ADR-0037 clamp
	       oee_a = COALESCE(LEAST(COALESCE(a.raw_running, 0), b.ts_total) / NULLIF(b.ts_total, 0), 0),
	       oee_q = LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1),
	       oee_p = COALESCE(
	             COALESCE(e.net / NULLIF((b.ts_total / 60.0) * NULLIF(e.ideal_speed, 0), 0), 0)
	             / NULLIF(
	                 COALESCE(LEAST(COALESCE(a.raw_running, 0), b.ts_total) / NULLIF(b.ts_total, 0), 0)
	                 * COALESCE(e.net / NULLIF(e.gross, 0), 0), 0), 0)
	  FROM bounds b
	  LEFT JOIN active a ON a.id_equipment = b.id_equipment AND a.ts_value = b.ts_value
	 WHERE e.id_equipment = b.id_equipment AND e.ts_value = b.ts_value
	   AND e.ts_value >= now() - interval '25 day'`

// Test/parity accessors — single-source emission. Deliberately NOT part of
// HourStatementsForParity / ShiftStatementsForParity (those are diffed against
// the prod engine, which has no counters-only fallback). The golden test drives
// these directly against a hand-built state-less fixture.
func HourCountsAvailSQLForParity() string  { return hourCountsAvailSQL }
func ShiftCountsAvailSQLForParity() string { return shiftCountsAvailSQL }
