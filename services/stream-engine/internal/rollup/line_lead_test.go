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

// #207: the SHIFT line-lead lines-CTE window was widened 2d → 25d so RunShift's
// oldest-first backlog drain (30-day eligible set) computes LINE grains for an
// outage older than the live 2-day lookback. Guard the constant so a future edit
// can't silently re-narrow it, and confirm it agrees with the pass's own UPDATE
// guard so the whole selected set is writable.
func TestShiftLineLeadWindow_widened(t *testing.T) {
	sql := ShiftLineLeadSQLForParity()
	if strings.Contains(sql, "interval '2 days'") {
		t.Error("shift line-lead still capped at 2 days — outage-old line shifts won't backfill")
	}
	if !strings.Contains(sql, "el.ts_value >= now() - interval '25 day'") {
		t.Error("shift line-lead lines-CTE window must be widened to 25 days (matches the UPDATE guard)")
	}
	if !strings.Contains(sql, "e.ts_value >= now() - interval '25 day'") {
		t.Error("shift line-lead UPDATE guard drifted from 25 days")
	}
	// The HOUR line-lead pass is driven purely by hour_elig (no ts_value window in
	// its lines CTE); it must carry neither the 2d nor the 25d shift filter.
	hour := HourLineLeadSQLForParity()
	if strings.Contains(hour, "interval '2 days'") || strings.Contains(hour, "interval '25 day'") {
		t.Error("hour line-lead unexpectedly gained a lines-CTE ts_value window")
	}
}
