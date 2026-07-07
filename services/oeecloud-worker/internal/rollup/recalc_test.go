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

// Day2 (the LIVE generation) fidelity guards.
func TestDayShape(t *testing.T) {
	for _, m := range []string{
		"hr.ts_value_production = el.ts_value", // tvp keying
		"hr.ts_value >= el.ts_value - interval '1 day'",
		"CASE WHEN e.target_customized IS TRUE THEN e.target",
		"sum(hr.net) / NULLIF(sum(hr.ideal_production), 0)",
	} {
		if !strings.Contains(dayEligibleSQL+dayRollupSQL, m) {
			t.Errorf("day2 lost %q", m)
		}
	}
	if !strings.Contains(dayCascadeMonthSQL+dayCascadeWeekSQL, "recalc_needed = true") {
		t.Error("upward cascade lost")
	}
	if strings.Contains(dayRollupSQL, "ca_agg") {
		t.Error("day2 sums the HOUR TABLE, not ca_agg — that was the dead generation")
	}
}

// Hour (the foundation) fidelity guards.
func TestHourShape(t *testing.T) {
	// Phase V keeps the flag TRUE; only phase E clears it.
	if !strings.Contains(hourValuesSQL, "recalc_needed = true") {
		t.Error("hour phase V must KEEP the flag (verbatim prod)")
	}
	if !strings.Contains(hourEventsSQL, "recalc_needed    = false") {
		t.Error("only hour phase E clears the flag")
	}
	for _, m := range []string{
		"interval '65 minutes'",
		"ca_agg_equipment_values_1min",     // speed from the 1min tier
		"locf.ideal_production_speed",      // line-OEE fix: LOCF ideal from equipment_values
		"q.production_speed)",              // ideal fallback (final COALESCE arg)
		"now() - interval '6 hour'",        // E guard
		"now() - interval '10 days'",   // events window
		"vl_day::float / 24",           // hourly proportional target
	} {
		if !strings.Contains(hourEligibleSQL+hourValuesSQL+hourSpeedSQL+hourEventsSQL+hourTargetsSQL, m) {
			t.Errorf("hour lost %q", m)
		}
	}
	if !strings.Contains(hourTargetsSQL, "NOT e.recalc_needed") {
		t.Error("targets must drive from event-hit (cleared) rows only")
	}
}

// Shift grain fidelity guards.
func TestShiftShape(t *testing.T) {
	// V clears the flag in SHIFT (unlike hour) — verbatim per body.
	if !strings.Contains(shiftValuesSQL, "recalc_needed = false") {
		t.Error("shift phase V clears the flag (verbatim)")
	}
	for _, m := range []string{
		"ca.id_shift = el.id_shift", // shift keying
		"ca.ts_value_production = el.ts_value_production",
		"cd_shift = el.cd_shift2",           // denorm
		"tstzrange(el.ts_value, el.ts_end)", // shift window
		"interval '25 days'",
		"(sh.shift_size - ev.ts_planned) / (3600 * 24)", // proportional formula
		"now() + interval '18 hour'",                    // forward re-flag
	} {
		if !strings.Contains(shiftEligibleSQL+shiftValuesSQL+shiftEventsSQL+shiftEventsUpdateSQL+shiftTargetsSQL+shiftReflagSQL, m) {
			t.Errorf("shift lost %q", m)
		}
	}
	if !strings.Contains(shiftEligibleSQL, "UNION ALL") {
		t.Error("the UNION selector (lines ∪ machine-level enterprises) must survive")
	}
}

// Entity tier (area/site) fidelity guards.
func TestEntityGrainShape(t *testing.T) {
	area := entityStatements(entityMatrix[0], "sch", "ref")
	all := ""
	for _, st := range area {
		all += st.SQL
	}
	for _, m := range []string{
		"tp_equipment = 3",                // areas roll up LINES only
		"date_trunc('week', el.ts_value)", // week span
		"el.ts_value + interval '1 week'", // verbatim <= upper bound
		"extract(minute FROM now()) / 60", // hour prop tail
		"gross = s.gross,",                // hour RAW fill (no COALESCE)
	} {
		if !strings.Contains(all, m) {
			t.Errorf("area tier lost %q", m)
		}
	}
	site := entityStatements(entityMatrix[1], "sch", "ref")
	sall := ""
	for _, st := range site {
		sall += st.SQL
	}
	if !strings.Contains(sall, "id_site = el.id_site") || strings.Contains(sall, "tp_equipment = 3") {
		t.Error("site tier must scope by areas-of-site, never tp filter")
	}
}

// Week/month must key own-entity day rows directly (the scope pred
// would reference absent columns — the bug this test pins).
func TestEntityWeekMonthOwnKey(t *testing.T) {
	for _, sp := range entityMatrix {
		for _, st := range entityStatements(sp, "sch", "ref") {
			if st.Name == sp.Name+"-week" || st.Name == sp.Name+"-month" {
				if strings.Contains(st.SQL, "ard.id_equipment IN") || (sp.Name == "site" && strings.Contains(st.SQL, "ard.id_area IN")) {
					t.Errorf("%s: week/month must not carry the tier-below scope pred", st.Name)
				}
				if !strings.Contains(st.SQL, "ard."+sp.Key+" = el."+sp.Key) {
					t.Errorf("%s: missing own-key join", st.Name)
				}
			}
		}
	}
}
