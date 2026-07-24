package rollup

import (
	"strings"
	"testing"
)

// plannedDowntimeExpr is the single classification knob for ADR-0037 (c). These
// cheap text assertions run WITHOUT Postgres (unlike the -tags golden DB test) so
// CI catches a regression to the off-path — which must stay prod-verbatim — or a
// NULL-unsafe on-path, on every build.
func TestPlannedDowntimeExpr(t *testing.T) {
	off := plannedDowntimeExpr(false)
	if off != "ee.planned_downtime = true" {
		t.Errorf("off predicate = %q, want the prod-verbatim %q", off, "ee.planned_downtime = true")
	}
	on := plannedDowntimeExpr(true)
	// On-path must still REQUIRE planned_downtime=true (only planned time is ever
	// subtracted) and EXCLUDE genuine changeover NULL-safely (IS DISTINCT FROM true,
	// not "= false", so a planned event with change_over NULL stays counted).
	if !strings.Contains(on, "ee.planned_downtime = true") {
		t.Errorf("on predicate %q lost the planned_downtime=true requirement", on)
	}
	if !strings.Contains(on, "ee.change_over IS DISTINCT FROM true") {
		t.Errorf("on predicate %q must exclude changeover NULL-safely via IS DISTINCT FROM true", on)
	}
	if strings.Contains(on, "change_over = false") {
		t.Errorf("on predicate %q uses NULL-unsafe `= false` (drops planned rows with NULL change_over)", on)
	}
}

// The parity accessors are diffed against prod (F2), which has no changeover
// reclassification, so their event SQL MUST embed the off-path predicate and must
// NOT carry the on-path exclusion — regardless of any runtime flag. This freezes
// "flags-off golden/parity is byte-identical" at the SQL-text level.
func TestParityAccessorsUseOffPredicate(t *testing.T) {
	hourEvents := ""
	for _, s := range HourStatementsForParity("public", "public") {
		if s.Name == "events" {
			hourEvents = s.SQL
		}
	}
	shiftEvents := ""
	for _, s := range ShiftStatementsForParity("public", "public") {
		if s.Name == "events-bank" {
			shiftEvents = s.SQL
		}
	}
	for name, sql := range map[string]string{"hour": hourEvents, "shift": shiftEvents} {
		if sql == "" {
			t.Fatalf("%s parity accessor: could not find the events statement", name)
		}
		if !strings.Contains(sql, "CASE WHEN ee.planned_downtime = true THEN") {
			t.Errorf("%s parity events SQL lost the prod-verbatim ts_planned predicate", name)
		}
		if strings.Contains(sql, "IS DISTINCT FROM true") {
			t.Errorf("%s parity events SQL leaked the changeover-availability on-path (breaks prod parity)", name)
		}
	}
}
