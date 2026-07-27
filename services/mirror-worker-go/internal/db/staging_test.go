package db

import (
	"strings"
	"testing"
)

// Guard for the ADR-0012 fan-out invariant: the delta INSERT must take
// its timestamp as a bind parameter, computed once in Go. A per-statement
// now() would give each flow a different (ts_value, id_equipment) — the
// parity join key — making cross-flow row comparison impossible.
func TestValueDeltaSQLUsesSharedTimestamp(t *testing.T) {
	if strings.Contains(sqlInsertValueDelta, "now()") {
		t.Error("delta insert must bind ts as a parameter, not now() — shared parity join key across flows")
	}
	if !strings.Contains(sqlInsertValueDelta, "%s.equipment_values") {
		t.Error("delta insert must be schema-parameterized for shadow fan-out")
	}
}

// Guard the invariants that make the prod-terminal orphan close 23514-safe AND
// status=1-reaching — the entire point of the fix. The live check constraint
// production_orders_ts_start_ts_end demands ts_start < ts_end STRICTLY for a
// status=3 row (a zero-duration close is REJECTED — the bug that surfaced in
// staging verification), and these orphans are late-mirrored so staging ts_start
// is usually AFTER prod's finish ts. Regressing any of these re-opens the wedge
// (894561) or the constraint trip.
func TestCloseProdTerminalOrphanHeader_StrictConstraintSafeAndWidened(t *testing.T) {
	sql := sqlCloseProdTerminalOrphanHeader
	// Must reach the never-started orphan (status=1), not just status=2.
	if !strings.Contains(sql, "status IN (1, 2)") {
		t.Error("header close must match status IN (1,2) — a status=1 orphan (894561) is otherwise unreachable")
	}
	// Must pin ts_end to the prod finish ts (closeTs, $2) — the faithful close
	// moment — NOT to now()/GREATEST(ts_start,...), which for a late-mirrored
	// orphan would show it ending long after prod actually finished.
	if !strings.Contains(sql, "ts_end = $2") {
		t.Error("header close must set ts_end = closeTs (prod finish ts)")
	}
	// Must anchor ts_start STRICTLY before ts_end via a 1-second floor so the
	// status=3 clause (ts_start < ts_end, strict) holds for a NULL start AND a
	// start that is >= closeTs. A COALESCE/GREATEST that can yield ts_start ==
	// ts_end trips 23514.
	if !strings.Contains(sql, "LEAST(COALESCE(ts_start, $2::timestamptz), $2::timestamptz - interval '1 second')") {
		t.Error("header close must anchor ts_start to LEAST(existing, closeTs-1s) for a STRICT ts_start < ts_end")
	}
	if strings.Contains(sql, "GREATEST") {
		t.Error("ts_end must not be GREATEST-clamped — a late-mirrored ts_start > closeTs would push the close past the real finish ts and (at equality) trip the strict 23514 check")
	}
	// Must actually finish the PO.
	if !strings.Contains(sql, "status = 3") {
		t.Error("header close must set status=3 (finished)")
	}
}
