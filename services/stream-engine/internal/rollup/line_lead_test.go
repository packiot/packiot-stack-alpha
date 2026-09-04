// Non-DB unit tests for the line-from-lead derivation (line_lead.go): the
// engagement gate and the fmt.Sprintf formatting of the two SQL consts. These
// run in the default `go test ./internal/rollup` (no golden build tag, no DB);
// the exact data-path assertions live in line_lead_golden_test.go.
package rollup

import (
	"fmt"
	"strings"
	"testing"
)

func TestEngagedLineLead(t *testing.T) {
	cases := []struct {
		name string
		c    CountersAvail
		want bool
	}{
		{"all-set", CountersAvail{LineLeadEnabled: true, LineLeadEnterprises: []int{3}, IdleTimeoutSec: 300}, true},
		{"disabled", CountersAvail{LineLeadEnabled: false, LineLeadEnterprises: []int{3}, IdleTimeoutSec: 300}, false},
		{"no-enterprises", CountersAvail{LineLeadEnabled: true, LineLeadEnterprises: nil, IdleTimeoutSec: 300}, false},
		{"zero-timeout", CountersAvail{LineLeadEnabled: true, LineLeadEnterprises: []int{3}, IdleTimeoutSec: 0}, false},
		{"zero-value", CountersAvail{}, false},
	}
	for _, tc := range cases {
		if got := tc.c.engagedLineLead(); got != tc.want {
			t.Errorf("%s: engagedLineLead() = %v, want %v", tc.name, got, tc.want)
		}
	}
	// The line-lead gate is independent of the counters-avail gate: a
	// line-lead-only config must NOT engage the (opposite) fallback.
	c := CountersAvail{LineLeadEnabled: true, LineLeadEnterprises: []int{3}, IdleTimeoutSec: 300}
	if c.engaged() {
		t.Error("line-lead-only config must not engage the counters-avail fallback")
	}
}

// TestLineLeadSQLFormatting guards against a positional-verb mismatch: every
// %[n]s/%[n]d in the two consts must be supplied, so a formatted statement
// never contains a `%!` error verb that would explode at Exec time.
func TestLineLeadSQLFormatting(t *testing.T) {
	shift := fmt.Sprintf(ShiftLineLeadSQLForParity(), "ev", "ref", pgIntArrayLiteral([]int{3, 4}), 300)
	hour := fmt.Sprintf(HourLineLeadSQLForParity(), "ev", "ref", pgIntArrayLiteral([]int{3}), 300)
	for _, tc := range []struct{ name, sql string }{{"shift", shift}, {"hour", hour}} {
		if strings.Contains(tc.sql, "%!") {
			t.Errorf("%s SQL has an unsatisfied fmt verb (%%!): %s", tc.name, tc.sql)
		}
		if !strings.Contains(tc.sql, "ev.equipment_oee_") {
			t.Errorf("%s SQL missing EvSchema-qualified target table", tc.name)
		}
		if !strings.Contains(tc.sql, "ref.equipments") {
			t.Errorf("%s SQL missing RefSchema-qualified equipments", tc.name)
		}
		if !strings.Contains(tc.sql, "'{3") {
			t.Errorf("%s SQL missing the enterprise array literal", tc.name)
		}
	}
}
