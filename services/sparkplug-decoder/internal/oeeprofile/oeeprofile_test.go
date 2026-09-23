package oeeprofile

import (
	"testing"

	calc "github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/transforms/calc_production_counters"
)

// TestDeriveUnitTopicMatchesParseTopic is the load-bearing test: the DB-built
// margin map key MUST equal the key the decoder's Calc looks up per message
// (calc_production_counters.parseTopicFull, via the exported ParseTopic). If
// this drifts, a client's authored spike_margin becomes a dead entry (lookup
// miss → the env default silently governs → the per-client knob does nothing).
// We assert deriveUnitTopic(rawTopic) equals ParseTopic(rawTopic + "***TRIG")
// for the exact eq47/L5 topics WS1 clamps, plus a line own-stream.
func TestDeriveUnitTopicMatchesParseTopic(t *testing.T) {
	cases := []struct {
		raw  string
		want string
	}{
		// eq47/L5 — the counter-anomaly line the guard fixes.
		{"CPACK/SC/LINHAS/L5/TEXA/Admin/ProdConsumedCount/47/Unit", "CPACK/SC/LINHAS/L5/TEXA"},
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit", "CPACK/SC/LINHAS/L5/BREYER"},
		{"CPACK/SC/CELULA1/CER400/CER400/Status/ProdProcessedCount/12/Unit", "CPACK/SC/CELULA1/CER400/CER400"},
		// LINE own-stream (segment 4 is a PackML keyword) → 4-segment unit topic.
		{"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/51/Unit", "CPACK/SC/LINHAS/L5"},
	}
	for _, c := range cases {
		got := deriveUnitTopic(c.raw)
		if got != c.want {
			t.Errorf("deriveUnitTopic(%q) = %q, want %q", c.raw, got, c.want)
		}
		unit, _, err := calc.ParseTopic(c.raw + "***TRIG")
		if err != nil {
			t.Fatalf("ParseTopic(%q) errored: %v", c.raw+"***TRIG", err)
		}
		if got != unit {
			t.Errorf("key drift: deriveUnitTopic=%q but ParseTopic=%q for %q", got, unit, c.raw)
		}
	}
}

// TestDeriveUnitTopicIdempotent proves the derivation is a no-op on an already-
// canonical equipment/line topic (the shortest packml_register row the query
// picks), so a DB key always matches the live lookup regardless of which row
// DISTINCT ON returned.
func TestDeriveUnitTopicIdempotent(t *testing.T) {
	cases := []string{
		"CPACK/SC/LINHAS/L5/TEXA",
		"CPACK/SC/LINHAS/L5",
		"CPACK/SC/CELULA1/CER400/CER400",
	}
	for _, c := range cases {
		if got := deriveUnitTopic(c); got != c {
			t.Errorf("deriveUnitTopic(%q) = %q, want unchanged", c, got)
		}
	}
}

// TestWatcherZeroValueBeforeStart proves a freshly-constructed Watcher (never
// Start()-ed, e.g. because OEE_PROFILE_FROM_DB is off) reports an empty, non-nil
// margin map rather than nil/panicking — the caller (main.go) calls Margins()
// per message unconditionally, so it must be safe before any load.
func TestWatcherZeroValueBeforeStart(t *testing.T) {
	w := NewWatcher(0, nil)
	if got := w.Margins(); got == nil || len(got) != 0 {
		t.Errorf("Margins() before Start() = %v, want empty non-nil map", got)
	}
	if got := w.Tenants(); got != 0 {
		t.Errorf("Tenants() before Start() = %d, want 0", got)
	}
}

// TestNewWatcherDefaultsInterval proves a non-positive interval falls back to
// DefaultRefreshInterval, so a mis-set OEE_PROFILE_REFRESH_SECONDS can't spin a
// zero-duration ticker.
func TestNewWatcherDefaultsInterval(t *testing.T) {
	w := NewWatcher(0, nil)
	if w.interval != DefaultRefreshInterval {
		t.Errorf("interval = %v, want %v", w.interval, DefaultRefreshInterval)
	}
}
