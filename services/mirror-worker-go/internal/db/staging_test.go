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
