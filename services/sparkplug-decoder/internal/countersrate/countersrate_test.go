package countersrate

import (
	"testing"

	calc "github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/transforms/calc_production_counters"
)

// TestDeriveUnitTopicMatchesParseTopic is the load-bearing test: the DB-built
// map key MUST equal the key the decoder's Calc looks up at runtime
// (calc_production_counters.parseTopicFull, via the exported ParseTopic). If
// this drifts, every DB rate becomes a dead entry (lookup miss → counter dropped
// → the G5 bug we're fixing). We assert deriveUnitTopic(rawTopic) equals
// ParseTopic(rawTopic + "***TRIG") for representative CPACK topics.
func TestDeriveUnitTopicMatchesParseTopic(t *testing.T) {
	// Each raw topic is a full per-metric Sparkplug counter topic (the shape
	// packml_register per-metric rows hold). "***TRIG" is the trigger suffix
	// ParseTopic requires; deriveUnitTopic sees the bare body.
	cases := []struct {
		raw  string
		want string
	}{
		// Producing machine missing from the hand map (the G5 case).
		{"CPACK/SC/LINHAS/L10/DXL/Admin/ProdProcessedCount/564/Unit", "CPACK/SC/LINHAS/L10/DXL"},
		// Machine already in the hand map.
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit", "CPACK/SC/LINHAS/L5/BREYER"},
		{"CPACK/SC/CELULA1/CER400/CER400/Status/ProdProcessedCount/12/Unit", "CPACK/SC/CELULA1/CER400/CER400"},
		// LINE own-stream (segment 4 is a PackML keyword) → 4-segment unit topic.
		{"CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/51/Unit", "CPACK/SC/LINHAS/L8"},
	}
	for _, c := range cases {
		got := deriveUnitTopic(c.raw)
		if got != c.want {
			t.Errorf("deriveUnitTopic(%q) = %q, want %q", c.raw, got, c.want)
		}
		// Cross-check against the runtime lookup path itself.
		unit, _, err := calc.ParseTopic(c.raw + "***TRIG")
		if err != nil {
			t.Fatalf("ParseTopic(%q) errored: %v", c.raw+"***TRIG", err)
		}
		if got != unit {
			t.Errorf("key drift: deriveUnitTopic=%q but ParseTopic=%q for %q", got, unit, c.raw)
		}
	}
}

// TestDeriveUnitTopicIdempotent proves the derivation is a no-op on an
// already-canonical equipment-level topic (what packml_register's shortest row
// holds), so it is safe to run on either the canonical topic or a per-metric one.
func TestDeriveUnitTopicIdempotent(t *testing.T) {
	cases := []string{
		"CPACK/SC/LINHAS/L10/DXL", // 5-seg machine unit topic
		"CPACK/SC/LINHAS/L8",      // 4-seg line topic
		"CPACK/SC/CELULA1/CER400/CER400",
	}
	for _, c := range cases {
		if got := deriveUnitTopic(c); got != c {
			t.Errorf("deriveUnitTopic(%q) = %q, want unchanged", c, got)
		}
	}
}

// TestMergeEnvWins proves the env map overrides the DB map on a key collision
// (a manual COUNTERS_ONLY_IDEAL_RATES override survives), while DB-only and
// env-only keys both pass through.
func TestMergeEnvWins(t *testing.T) {
	db := map[string]float64{
		"CPACK/SC/LINHAS/L10/DXL":   100, // DB-only
		"CPACK/SC/LINHAS/L5/BREYER": 147, // collides with env → env wins
	}
	env := map[string]float64{
		"CPACK/SC/LINHAS/L5/BREYER": 200, // override
		"CPACK/SC/LINHAS/L4/PTH":    50,  // env-only
	}
	out := Merge(db, env)
	want := map[string]float64{
		"CPACK/SC/LINHAS/L10/DXL":   100,
		"CPACK/SC/LINHAS/L5/BREYER": 200,
		"CPACK/SC/LINHAS/L4/PTH":    50,
	}
	if len(out) != len(want) {
		t.Fatalf("Merge len = %d, want %d (%v)", len(out), len(want), out)
	}
	for k, v := range want {
		if out[k] != v {
			t.Errorf("Merge[%q] = %v, want %v", k, out[k], v)
		}
	}
	// Merge must not mutate inputs.
	if db["CPACK/SC/LINHAS/L5/BREYER"] != 147 {
		t.Errorf("Merge mutated the db input map")
	}
}
