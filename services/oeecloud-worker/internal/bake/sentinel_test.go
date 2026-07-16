package bake

import "testing"

// row is a compact planeRow builder for the tests.
// (count, running_time, duration | gross, net, oee)
func row(count, rt, dur int64, gross, net, oee float64) planeRow {
	return planeRow{Count: count, RunningTime: rt, Duration: dur, Gross: gross, Net: net, MaxOEE: oee}
}

// TestCompareLines pins the reframed (#43 + live #474) per-natural-key verdict:
//   - GATE 1: the event-derived core {count, running_time, duration} must be
//     byte-exact on EVERY line (incl. absolute-control lines like L8).
//   - Counter (gross/net) divergences are NON-GATING Info — they never change
//     the verdict, because F2 is a raw control and F3 runs the cutover.
func TestCompareLines(t *testing.T) {
	cases := []struct {
		name       string
		f2, f3     map[string]planeRow
		wantStatus string
		wantInfo   int
	}{
		{
			name:       "delta-fed line byte-identical passes (L6/L10 shape)",
			f2:         map[string]planeRow{"L6|3": row(7, 184260, 228600, 396066, 365852, 0.90)},
			f3:         map[string]planeRow{"L6|3": row(7, 184260, 228600, 396066, 365852, 0.90)},
			wantStatus: "PASS",
			wantInfo:   0,
		},
		{
			// L8 shape: core byte-exact, counters diverge by billions. Must PASS
			// (core matches); the counter delta is INFO only. This is the case
			// that used to false-fail.
			name:       "absolute-control line (L8): core byte-exact, counter divergence is INFO not FAIL",
			f2:         map[string]planeRow{"L8|3": row(7, 88800, 228600, 4.9e9, 4.8e9, 20234.3)},
			f3:         map[string]planeRow{"L8|3": row(7, 88800, 228600, 3.2e8, 3.1e8, 5349.9)},
			wantStatus: "PASS",
			wantInfo:   1,
		},
		{
			// L3 shape: F2 UNDER-counts (gross 0) while F3 has 184855, and F2
			// oee=0 (≤1.0). Core byte-exact ⇒ PASS; counter is INFO. Proves we do
			// NOT gate on the (broken) "F2 oee ≤ 1.0 ⇒ assert counters" rule.
			name:       "F2-undercount line (L3, F2 oee 0): core byte-exact ⇒ PASS, counter INFO",
			f2:         map[string]planeRow{"L3|3": row(8, 171900, 228600, 0, 0, 0.0)},
			f3:         map[string]planeRow{"L3|3": row(8, 171900, 228600, 184855, 182096, 0.80)},
			wantStatus: "PASS",
			wantInfo:   1,
		},
		{
			// THE regression this gate MUST catch: a running_time divergence on
			// an absolute-control line. Counters exempt, but core is byte-exact-
			// required on every line → FAIL.
			name:       "running_time drift on absolute-control line FAILS (core is byte-exact on all lines)",
			f2:         map[string]planeRow{"L8|3": row(7, 88800, 228600, 4.9e9, 4.8e9, 20234.3)},
			f3:         map[string]planeRow{"L8|3": row(7, 88801, 228600, 3.2e8, 3.1e8, 5349.9)},
			wantStatus: "FAIL",
		},
		{
			// The int-overflow regression class at the aggregate: running_time
			// blows up on F3 (112,000,000) → core diverges → FAIL (belt-and-
			// suspenders with the per-row overflow bound in GATE 2).
			name:       "running_time overflow on one plane FAILS via core byte-exact",
			f2:         map[string]planeRow{"L8|3": row(7, 11195, 228600, 100, 100, 0.5)},
			f3:         map[string]planeRow{"L8|3": row(7, 112000000, 228600, 100, 100, 0.5)},
			wantStatus: "FAIL",
		},
		{
			name:       "count divergence FAILS (structural)",
			f2:         map[string]planeRow{"L6|3": row(7, 184260, 228600, 396066, 365852, 0.90)},
			f3:         map[string]planeRow{"L6|3": row(8, 184260, 228600, 396066, 365852, 0.90)},
			wantStatus: "FAIL",
		},
		{
			name:       "key present in F2 absent in F3 fails",
			f2:         map[string]planeRow{"L6|3": row(7, 184260, 228600, 396066, 365852, 0.90), "L10|3": row(7, 1, 1, 1, 1, 0.5)},
			f3:         map[string]planeRow{"L6|3": row(7, 184260, 228600, 396066, 365852, 0.90)},
			wantStatus: "FAIL",
		},
		{
			name:       "dry machines (gross 0≡0) pass, no info",
			f2:         map[string]planeRow{"BREYER1|1": row(8, 0, 228600, 0, 0, 0)},
			f3:         map[string]planeRow{"BREYER1|1": row(8, 0, 228600, 0, 0, 0)},
			wantStatus: "PASS",
			wantInfo:   0,
		},
		{
			name:       "both empty skips",
			f2:         map[string]planeRow{},
			f3:         map[string]planeRow{},
			wantStatus: "SKIP",
		},
		{
			name:       "one side empty skips (cold-stack guard)",
			f2:         map[string]planeRow{"L6|3": row(7, 184260, 228600, 396066, 365852, 0.90)},
			f3:         map[string]planeRow{},
			wantStatus: "SKIP",
		},
	}
	for _, c := range cases {
		got := compareLines("equipment_runtime_shift", 3, c.f2, c.f3)
		if got.Status != c.wantStatus {
			t.Errorf("%s: status=%q want %q (details=%v)", c.name, got.Status, c.wantStatus, got.Details)
		}
		if c.wantInfo != 0 && len(got.Info) != c.wantInfo {
			t.Errorf("%s: info=%d want %d (%v)", c.name, len(got.Info), c.wantInfo, got.Info)
		}
	}
}

// TestCompareRawCount pins GATE 3: raw row count count-tolerant + skip-on-empty.
func TestCompareRawCount(t *testing.T) {
	cases := []struct {
		name         string
		f2, f3       int64
		f2emp, f3emp bool
		wantStatus   string
	}{
		{"within emit-leg tolerance passes", 97512, 97474, false, false, "PASS"},
		{"beyond tolerance fails", 97512, 60000, false, false, "FAIL"},
		{"both empty skips", 0, 0, true, true, "SKIP"},
		{"one empty skips", 97512, 0, false, true, "SKIP"},
	}
	for _, c := range cases {
		got := compareRawCount(3, c.f2, c.f3, c.f2emp, c.f3emp)
		if got.Status != c.wantStatus {
			t.Errorf("%s: status=%q want %q", c.name, got.Status, c.wantStatus)
		}
	}
}

// TestSentinelReportFailed pins the gate's overall verdict: only FAIL surfaces
// or overflow violations fail; SKIP and counter-Info do not.
func TestSentinelReportFailed(t *testing.T) {
	cases := []struct {
		name string
		rep  SentinelReport
		want bool
	}{
		{"all pass", SentinelReport{Surfaces: []SurfaceOutcome{{Status: "PASS"}}}, false},
		{"a skip alone does not fail", SentinelReport{Surfaces: []SurfaceOutcome{{Status: "PASS"}, {Status: "SKIP"}}}, false},
		{"counter Info does not fail", SentinelReport{Surfaces: []SurfaceOutcome{{Status: "PASS", Info: []string{"L8|3 gross diverges"}}}}, false},
		{"a surface fail fails the gate", SentinelReport{Surfaces: []SurfaceOutcome{{Status: "PASS"}, {Status: "FAIL"}}}, true},
		{"an overflow violation fails the gate",
			SentinelReport{
				Surfaces: []SurfaceOutcome{{Status: "PASS"}},
				Overflow: []OverflowOutcome{{Surface: "equipment_runtime_shift", Side: "F3", Violations: []string{"running_time=112000000"}}},
			}, true},
		{"clean overflow list does not fail",
			SentinelReport{Overflow: []OverflowOutcome{{Surface: "x", Side: "F2", Violations: nil}}}, false},
	}
	for _, c := range cases {
		if got := c.rep.Failed(); got != c.want {
			t.Errorf("%s: Failed()=%v want %v", c.name, got, c.want)
		}
	}
}
