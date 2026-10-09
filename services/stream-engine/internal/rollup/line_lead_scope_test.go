package rollup

import (
	"strings"
	"testing"
)

// TestLineLeadScope_NoOverridesIsByteIdentical pins the parity promise: a
// tenant without per-line OEE overrides renders EXACTLY the pre-override SQL
// in every grain, so its OEE numbers cannot change.
func TestLineLeadScope_NoOverridesIsByteIdentical(t *testing.T) {
	ents := pgIntArrayLiteral([]int{3, 5})
	if got := (LineLeadScope{Enterprises: []int{3, 5}}).Predicate(ents); got != "eq.id_enterprise = ANY('{3,5}'::bigint[])" {
		t.Fatalf("predicate = %q", got)
	}
	for name, tpl := range map[string]string{"hour": hourLineLeadSQL, "shift": shiftLineLeadSQL} {
		old := strings.Replace(tpl, "AND %[6]s", "AND eq.id_enterprise = ANY(%[6]s)", 1)
		ca := CountersAvail{LineLeadEnterprises: []int{3, 5}}
		newSQL := strings.Replace(tpl, "%[6]s", ca.LineLead().Predicate(ents), 1)
		oldSQL := strings.Replace(old, "%[6]s", ents, 1)
		if newSQL != oldSQL {
			t.Errorf("%s: rendered SQL changed for a tenant without overrides", name)
		}
	}
	if ComputeValuesSQLForParity() != strings.Replace(computeValuesSQL, "%[6]s", "eq.id_enterprise = ANY($2::int[])", 1) {
		t.Error("compute parity SQL drifted")
	}
}

// TestLineLeadScope_Overrides: an opted-in line joins even if its client isn't
// opted in; an opted-out line leaves even if its client is.
func TestLineLeadScope_Overrides(t *testing.T) {
	s := LineLeadScope{Enterprises: []int{5}, OptIn: []int{700}, OptOut: []int{510}}
	want := "((eq.id_enterprise = ANY($2::int[]) AND NOT eq.id_equipment = ANY('{510}'::bigint[])) OR eq.id_equipment = ANY('{700}'::bigint[]))"
	if got := s.Predicate("$2::int[]"); got != want {
		t.Fatalf("predicate =\n %s\nwant\n %s", got, want)
	}
	if !(LineLeadScope{OptIn: []int{700}}).Any() {
		t.Error("a per-line opt-in alone must engage the line-lead pass")
	}
	ca := CountersAvail{LineLeadEnabled: true, IdleTimeoutSec: 300, LineLeadOptIn: []int{700}}
	if !ca.engagedLineLead() {
		t.Error("engagedLineLead must be true with only a per-line opt-in")
	}
}

// TestLineLeadParityAccessorsKeepContract: goldens + port-parity pass the
// enterprise LITERAL as %[6]s; the accessors must still render valid SQL.
func TestLineLeadParityAccessorsKeepContract(t *testing.T) {
	for name, sql := range map[string]string{"shift": ShiftLineLeadSQLForParity(), "hour": HourLineLeadSQLForParity()} {
		got := fmtRP(sql, "golden", pgIntArrayLiteral([]int{3}), 300)
		if !strings.Contains(got, "AND eq.id_enterprise = ANY('{3}'::bigint[])") || strings.Contains(got, "AND '{3}'") {
			t.Errorf("%s parity SQL lost the enterprise predicate", name)
		}
	}
}
