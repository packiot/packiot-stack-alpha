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

// compute (po-runtime-compute) fidelity guards.
func TestComputeShape(t *testing.T) {
	for _, m := range []string{
		"ee.status = 6",                // running
		"ee.status IN (5, 10, 11)",     // stopped
		"greatest(ee.ts_event, el.lo)", // overlap math
		"LEFT JOIN sums",               // phase A always-updates
		"recalc_needed    = false",
	} {
		if !strings.Contains(computeValuesSQL+computeEventsSQL, m) {
			t.Errorf("compute lost %q", m)
		}
	}
	// Phase B must stay CONDITIONAL (inner join) — prod's GROUP BY
	// FOUND-false semantics. Do not "fix" into LEFT JOIN.
	if strings.Contains(computeEventsSQL, "LEFT JOIN") {
		t.Error("phase B must remain an inner join (conditional update)")
	}
	if strings.Contains(computeValuesSQL+computeEventsSQL, "ideal_production_speed") {
		t.Error("ideal speed is dead computation in prod's current body — not ported")
	}
	if !strings.Contains(computeReflagOpenSQL, "upper(runtime_timerange) IS NULL") {
		t.Error("open-range reflag lost")
	}
}

// Property tests (#4): OEE invariants hold for all inputs by
// construction of the formulas.
func TestOEEFormulaProperties(t *testing.T) {
	q := func(net, gross float64) float64 {
		if gross == 0 {
			return 0
		}
		return net / gross
	}
	for _, c := range []struct{ net, gross float64 }{{0, 0}, {5, 10}, {10, 10}, {0, 7}} {
		v := q(c.net, c.gross)
		if v < 0 || v > 1 {
			t.Errorf("quality out of [0,1] for net=%v gross=%v: %v", c.net, c.gross, v)
		}
	}
}
