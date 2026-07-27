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

// Guard the two invariants that make the prod-terminal orphan close 23514-safe
// AND status=1-reaching — the entire point of the fix. Regressing either
// re-opens the wedge (894561) or the constraint trip (894720).
func TestCloseProdTerminalOrphanHeader_NullSafeAndWidened(t *testing.T) {
	sql := sqlCloseProdTerminalOrphanHeader
	// Must reach the never-started orphan (status=1), not just status=2.
	if !strings.Contains(sql, "status IN (1, 2)") {
		t.Error("header close must match status IN (1,2) — a status=1 orphan (894561) is otherwise unreachable")
	}
	// Must seed a NULL ts_start so setting ts_end can't trip 23514.
	if !strings.Contains(sql, "ts_start = COALESCE(ts_start, $2)") {
		t.Error("header close must COALESCE a NULL ts_start to closeTs (zero-duration) to avoid check 23514")
	}
	// Must clamp ts_end so ts_end >= ts_start always (staging ts_start can be
	// AFTER prod's finish ts for a late-mirrored orphan).
	if !strings.Contains(sql, "ts_end = GREATEST($2::timestamptz, COALESCE(ts_start, $2))") {
		t.Error("header close must GREATEST-clamp ts_end >= ts_start to avoid an inverted range (23514)")
	}
	// Must actually finish the PO.
	if !strings.Contains(sql, "status = 3") {
		t.Error("header close must set status=3 (finished)")
	}
}
