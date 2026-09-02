package rollup

import (
	"fmt"
	"strings"
	"testing"
)

// The backfill's correctness rests on one claim: it recomputes an old hour with
// the SAME math as the live rollup, only reaching further back. widenHourWindows
// must therefore change ONLY the recency bounds — never a join key, an aggregate,
// or a WHERE that selects which events belong to the hour.
func TestWidenHourWindows_replacesOnlyRecencyBounds(t *testing.T) {
	// The live events pass: has both the 65-min value-window (none here) and the
	// 6h UPDATE guard + the el.ts_value-anchored event math that must NOT change.
	got := widenHourWindows(fmt.Sprintf(hourEventsSQL, "public", plannedDowntimeExpr(false)))

	if strings.Contains(got, "interval '6 hour'") {
		t.Error("6h UPDATE guard not widened — old rows would still be blocked")
	}
	if !strings.Contains(got, "now() - interval '10 days'") {
		t.Error("expected the widened 10-day horizon")
	}
	// The event-to-hour anchoring (el.ts_value bounds, status filters) is the
	// math and must survive verbatim.
	for _, must := range []string{
		"greatest(ee.ts_event, el.ts_value)",
		"ee.status = 6",
		"el.ts_value + interval '1 hour'",
		"ee.ts_event >= now() - interval '10 days'", // 10-day retention already; unchanged
	} {
		if !strings.Contains(got, must) {
			t.Errorf("widen corrupted the event math — missing %q", must)
		}
	}
}

func TestWidenHourWindows_valuesPass65Min(t *testing.T) {
	got := widenHourWindows(fmt.Sprintf(hourValuesSQL, "public"))
	if strings.Contains(got, "interval '65 minutes'") {
		t.Error("65-min value window not widened — old buckets would be excluded from the cagg join")
	}
	// The real anchor (ca.ts_value = el.ts_value) must remain.
	if !strings.Contains(got, "ca.ts_value = el.ts_value") {
		t.Error("widen corrupted the values join anchor")
	}
}

// The backfill must FINALIZE the OEE decomposition like the live path, else a
// drained hour keeps a stale oee_p and oee != oee_a·oee_p·oee_q. Both the
// canonical reconcile and the legacy residual must be widened to the 10-day
// horizon (their live `now()-6h` guard would otherwise block every backfilled row).
func TestBackfillOeeFinalize_widened(t *testing.T) {
	rec := widenHourWindows(fmt.Sprintf(hourOeeReconcileSQL, "public"))
	if strings.Contains(rec, "interval '6 hour'") {
		t.Error("canonical reconcile 6h guard not widened — backfilled rows would be skipped")
	}
	if !strings.Contains(rec, "oee_a") || !strings.Contains(rec, "oee_p") {
		t.Error("reconcile finalize must write the A·P·Q waterfall")
	}
	oeeP := widenHourWindows(fmt.Sprintf(hourOeePSQL, "public"))
	if strings.Contains(oeeP, "interval '6 hour'") {
		t.Error("legacy oee_p 6h guard not widened — backfilled rows would be skipped")
	}
}

// The backfill eligibility must select OLD rows only (RunHour owns recent) and
// stay inside event retention, bounded and oldest-first.
func TestHourBackfillEligible_shape(t *testing.T) {
	q := fmt.Sprintf(hourBackfillEligibleSQL, "public", "public", 200)
	for _, must := range []string{
		"h.recalc_needed",
		"h.ts_value <  now() - interval '65 minutes'", // outside the live window
		"h.ts_value >= now() - interval '10 days'",    // within event retention
		"ORDER BY h.ts_value ASC",
		"LIMIT 200",
	} {
		if !strings.Contains(q, must) {
			t.Errorf("backfill eligibility missing %q", must)
		}
	}
}
