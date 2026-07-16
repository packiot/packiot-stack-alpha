package bake

import "testing"

// TestCompareKeyMaps pins the per-natural-key determinism verdict — the
// load-bearing decision the deploy gate makes. Adversarial cases the
// whole-surface aggregate (RunIdentityTick) would MISS are the point: a
// compensating per-line divergence that nets to zero across the surface.
func TestCompareKeyMaps(t *testing.T) {
	cases := []struct {
		name       string
		f2, f3     map[string]string
		countTol   bool
		wantStatus string
	}{
		{
			name:       "byte-identical derived grain passes",
			f2:         map[string]string{"L8|3": "8|100.000|11195.0", "L6|3": "8|50.000|9000.0"},
			f3:         map[string]string{"L8|3": "8|100.000|11195.0", "L6|3": "8|50.000|9000.0"},
			wantStatus: "PASS",
		},
		{
			// THE reason per-key exists: L8 +1000 gross, L6 -1000 gross. Surface
			// SUM is identical (150 vs 150) so a whole-surface fingerprint PASSES,
			// but two lines diverged. Per-key must FAIL.
			name:       "compensating per-line divergence (whole-surface would mask) fails",
			f2:         map[string]string{"L8|3": "8|100.000|11195.0", "L6|3": "8|50.000|9000.0"},
			f3:         map[string]string{"L8|3": "8|1100.000|11195.0", "L6|3": "8|-950.000|9000.0"},
			wantStatus: "FAIL",
		},
		{
			name:       "running_time gap on one line fails (byte-exact contract)",
			f2:         map[string]string{"L8|3": "8|100.000|11195.0"},
			f3:         map[string]string{"L8|3": "8|100.000|112000000.0"},
			wantStatus: "FAIL",
		},
		{
			name:       "count differs on a derived grain fails (structural)",
			f2:         map[string]string{"L8|3": "8|100.000|11195.0"},
			f3:         map[string]string{"L8|3": "7|100.000|11195.0"},
			wantStatus: "FAIL",
		},
		{
			name:       "key present in F2 absent in F3 fails",
			f2:         map[string]string{"L8|3": "8|100.000|11195.0", "L6|3": "8|50.000|9000.0"},
			f3:         map[string]string{"L8|3": "8|100.000|11195.0"},
			wantStatus: "FAIL",
		},
		{
			name:       "key present in F3 absent in F2 fails",
			f2:         map[string]string{"L8|3": "8|100.000|11195.0"},
			f3:         map[string]string{"L8|3": "8|100.000|11195.0", "GHOST|3": "1|5.000|60.0"},
			wantStatus: "FAIL",
		},
		{
			name:       "gross within 1% band passes",
			f2:         map[string]string{"L8|3": "8|100000000.000|11195.0"},
			f3:         map[string]string{"L8|3": "8|100500000.000|11195.0"},
			wantStatus: "PASS",
		},
		{
			name:       "raw surface count-tolerant within band passes",
			f2:         map[string]string{"__all__": "54689|1817080000.000|1844530000.000"},
			f3:         map[string]string{"__all__": "54709|1818400000.000|1845870000.000"},
			countTol:   true,
			wantStatus: "PASS",
		},
		{
			name:       "both sides empty skips (no data)",
			f2:         map[string]string{},
			f3:         map[string]string{},
			wantStatus: "SKIP",
		},
		{
			name:       "F3 entirely empty skips (cold-stack guard, not a regression)",
			f2:         map[string]string{"L8|3": "8|100.000|11195.0"},
			f3:         map[string]string{},
			wantStatus: "SKIP",
		},
		{
			name:       "F2 entirely empty skips (cold-stack guard)",
			f2:         map[string]string{},
			f3:         map[string]string{"L8|3": "8|100.000|11195.0"},
			wantStatus: "SKIP",
		},
	}
	for _, c := range cases {
		got := compareKeyMaps("surface", 3, c.f2, c.f3, c.countTol)
		if got.Status != c.wantStatus {
			t.Errorf("%s: status = %q (details=%v), want %q", c.name, got.Status, got.Details, c.wantStatus)
		}
	}
}

// TestSentinelReportFailed pins the gate's overall verdict: any FAIL surface or
// any overflow violation fails; SKIPs alone do not.
func TestSentinelReportFailed(t *testing.T) {
	cases := []struct {
		name string
		rep  SentinelReport
		want bool
	}{
		{"all pass", SentinelReport{Surfaces: []SurfaceOutcome{{Status: "PASS"}}}, false},
		{"a skip alone does not fail", SentinelReport{Surfaces: []SurfaceOutcome{{Status: "PASS"}, {Status: "SKIP"}}}, false},
		{"a surface fail fails the gate", SentinelReport{Surfaces: []SurfaceOutcome{{Status: "PASS"}, {Status: "FAIL"}}}, true},
		{"an overflow violation fails the gate even with all surfaces passing",
			SentinelReport{
				Surfaces: []SurfaceOutcome{{Status: "PASS"}},
				Overflow: []OverflowOutcome{{Surface: "equipment_runtime_shift", Side: "F3", Violations: []string{"running_time=112000000 exceeds span"}}},
			}, true},
		{"clean overflow list does not fail",
			SentinelReport{Overflow: []OverflowOutcome{{Surface: "x", Side: "F2", Violations: nil}}}, false},
	}
	for _, c := range cases {
		if got := c.rep.Failed(); got != c.want {
			t.Errorf("%s: Failed() = %v, want %v", c.name, got, c.want)
		}
	}
}
