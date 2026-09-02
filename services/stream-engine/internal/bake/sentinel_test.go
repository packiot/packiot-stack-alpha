package bake

import (
	"strings"
	"testing"
)

// TestSentinelReportFailed pins the F3 overflow gate's verdict: the gate fails
// iff SOME overflow surface has ≥1 violation. An empty report (no surfaces run)
// and clean surfaces (nil/empty Violations) both PASS. (After ADR-0032 Step 5
// the F2==F3 identity surfaces are gone; only the per-plane overflow bound gates.)
func TestSentinelReportFailed(t *testing.T) {
	cases := []struct {
		name string
		rep  SentinelReport
		want bool
	}{
		{"empty report passes", SentinelReport{}, false},
		{"clean surface passes",
			SentinelReport{Overflow: []OverflowOutcome{{Surface: "equipment_runtime_shift", Enterprise: 3, Violations: nil}}}, false},
		{"multiple clean surfaces pass",
			SentinelReport{Overflow: []OverflowOutcome{
				{Surface: "equipment_runtime_shift", Enterprise: 3},
				{Surface: "production_orders_runtime", Enterprise: 3},
			}}, false},
		{"a violation fails the gate (the L8 112M overflow class)",
			SentinelReport{Overflow: []OverflowOutcome{
				{Surface: "equipment_runtime_shift", Enterprise: 3, Violations: []string{
					`key "L8|3" running_time=112000000 exceeds span=11195s × 1.05 (int-overflow class)`}},
			}}, true},
		{"one clean + one violating still fails",
			SentinelReport{Overflow: []OverflowOutcome{
				{Surface: "equipment_runtime_shift", Enterprise: 3},
				{Surface: "production_orders_runtime", Enterprise: 3, Violations: []string{"running_time=-5 negative"}},
			}}, true},
	}
	for _, c := range cases {
		if got := c.rep.Failed(); got != c.want {
			t.Errorf("%s: Failed()=%v want %v", c.name, got, c.want)
		}
	}
}

// TestSentinelReportString sanity-checks the rendered verdict line so a green
// report reads PASS and a violating one reads FAIL with the count.
func TestSentinelReportString(t *testing.T) {
	clean := (&SentinelReport{Overflow: []OverflowOutcome{{Surface: "equipment_runtime_shift", Enterprise: 3}}}).String()
	if !strings.Contains(clean, "VERDICT: PASS") || !strings.Contains(clean, "violations=0") {
		t.Errorf("clean report should read PASS/0, got:\n%s", clean)
	}
	dirty := (&SentinelReport{Overflow: []OverflowOutcome{
		{Surface: "equipment_runtime_shift", Enterprise: 3, Violations: []string{"a", "b"}},
	}}).String()
	if !strings.Contains(dirty, "VERDICT: FAIL") || !strings.Contains(dirty, "violations=2") {
		t.Errorf("violating report should read FAIL/2, got:\n%s", dirty)
	}
}
