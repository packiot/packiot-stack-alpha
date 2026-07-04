package rollup

import (
	"strings"
	"testing"
)

// Formula fidelity: the OEE math must remain prod-verbatim.
func TestRecalcFormulas(t *testing.T) {
	for _, m := range []string{
		"s.net / NULLIF(s.gross, 0)",     // quality
		"((s.total - s.planned) / 60.0)", // oee denominator
		"s.run / NULLIF(s.avail, 0)",     // availability
		"recalc_needed = false",
		"LEFT JOIN sums s USING (id_production_order)", // prod zeroes no-row POs
		"runtime_timerange && tstzrange(now() - $1::interval, now())",
	} {
		if !strings.Contains(recalcSQL, m) {
			t.Errorf("recalc lost %q", m)
		}
	}
	for _, banned := range []string{"!= 6", "= 6", "'1 month'"} {
		if strings.Contains(recalcSQL, banned) {
			t.Errorf("hardcoded tenant/window %q — must be config", banned)
		}
	}
}

// The self-re-enqueue semantics (verbatim from prod's pass tail).
func TestReflagSemantics(t *testing.T) {
	if !strings.Contains(reflagRunningSQL, "status = 2") {
		t.Error("running POs must re-enqueue every pass")
	}
	if !strings.Contains(reflagRecentSQL, "interval '48 hours'") || !strings.Contains(reflagRecentSQL, "status = 3") {
		t.Error("finished POs must keep refreshing for 48h")
	}
}
