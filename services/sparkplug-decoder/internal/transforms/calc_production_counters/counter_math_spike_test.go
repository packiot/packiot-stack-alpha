package calc_production_counters

import "testing"

// TestClampSpikeIncrement covers WS1 — the counter-anomaly gross guard. It proves
// the CPACK eq47/L5 class (a 108951-in-a-minute jump on a ~100/min line) is clamped
// to the plausible ceiling, that legitimate production passes untouched, and that
// mis-configuration makes the guard INERT (never drops real production).
func TestClampSpikeIncrement(t *testing.T) {
	const minute = int64(60000)
	cases := []struct {
		name       string
		incr       int64
		idealRate  float64 // parts/min
		intervalMs int64
		marginK    float64
		wantIncr   int64
		wantClamp  bool
	}{
		// eq47/L5: 100/min line, 3x margin → ceiling 300/min; a 108951 jump clamps.
		{"eq47 spike clamps", 108951, 100, minute, 3, 300, true},
		// A big-but-plausible burst (line briefly above rate) under the ceiling passes.
		{"plausible burst passes", 250, 100, minute, 3, 250, false},
		{"exactly at ceiling passes", 300, 100, minute, 3, 300, false},
		{"just over ceiling clamps", 301, 100, minute, 3, 300, true},
		// Longer interval → proportionally higher ceiling (rate-based, not fixed).
		{"5-min interval scales ceiling", 1400, 100, 5 * minute, 3, 1400, false},
		{"5-min interval still clamps a spike", 100000, 100, 5 * minute, 3, 1500, true},
		// INERT guards — must return the raw increment, never drop production.
		{"idealRate 0 disables guard", 108951, 0, minute, 3, 108951, false},
		{"interval 0 disables guard", 108951, 100, 0, 3, 108951, false},
		{"marginK 0 disables guard", 108951, 100, minute, 0, 108951, false},
		{"zero increment untouched", 0, 100, minute, 3, 0, false},
		{"negative increment untouched", -50, 100, minute, 3, -50, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, clamped := clampSpikeIncrement(c.incr, c.idealRate, c.intervalMs, c.marginK)
			if got != c.wantIncr || clamped != c.wantClamp {
				t.Errorf("clampSpikeIncrement(%d, %g, %d, %g) = (%d, %v); want (%d, %v)",
					c.incr, c.idealRate, c.intervalMs, c.marginK, got, clamped, c.wantIncr, c.wantClamp)
			}
		})
	}
}
