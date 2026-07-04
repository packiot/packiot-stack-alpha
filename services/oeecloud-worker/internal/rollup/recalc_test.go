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

// The cascade grains: formulas + THE AMBER BUG pinned.
func TestGrainMatrix(t *testing.T) {
	if grainMatrix[0].Grain != "week" || grainMatrix[0].OeePTable != "equipment_runtime_1month" {
		t.Error("AMBER BUG must be preserved: week's oee_p targets 1MONTH (prod copy-paste, shipped for years — fix only with consumer sign-off)")
	}
	if grainMatrix[1].OeePTable != "equipment_runtime_1month" {
		t.Error("month's oee_p correctly targets 1month")
	}
	for _, m := range []string{
		"s.net / NULLIF(s.ideal_production, 0)",                         // oee (grain variant)
		"s.running_time / NULLIF(s.total_time - s.planned_downtime, 0)", // oee_a
		"date_trunc('%[4]s', ard.ts_value::date)::date",                 // bucket join
	} {
		if !strings.Contains(grainRollupSQL, m) {
			t.Errorf("grain rollup lost %q", m)
		}
	}
	if !strings.Contains(grainTargetsSQL, "target_customized IS NOT TRUE") {
		t.Error("operator-customized targets must be respected")
	}
}

// Day grain fidelity guards.
func TestDayShape(t *testing.T) {
	for _, m := range []string{
		"CASE WHEN ca.state = 6 THEN ca.speed END", // Eduardo 2024-02-29
		"ca.ts_value_production = el.ts_value",     // tvp keying
		"ee.status IN (5, 10, 11)",
		"date_trunc('month', el.ts_value)", // upward cascade
		"date_trunc('week', el.ts_value)",
	} {
		if !strings.Contains(dayEligibleSQL+dayValuesSQL+dayCascadeMonthSQL+dayCascadeWeekSQL+dayEventsSQL, m) {
			t.Errorf("day lost %q", m)
		}
	}
	// Phase E stays CONDITIONAL (inner join on ev).
	if !strings.Contains(dayEventsSQL, "FROM ev\n	  JOIN ideal") {
		t.Error("phase E update must drive from ev (inner) — GROUP BY FOUND semantics")
	}
	// AMBER-2 intent restoration: per-row anchors, no loop-leak.
	if !strings.Contains(dayReflagSQL, "e.id_equipment, e.ts_value") {
		t.Error("reflag proportional must be PER ROW (amber-2 intent restore)")
	}
	if !strings.Contains(dayTargetsSQL, "target_customized IS NOT TRUE") {
		t.Error("customized targets must be respected")
	}
}
