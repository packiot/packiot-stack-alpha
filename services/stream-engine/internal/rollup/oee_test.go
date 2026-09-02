// oee_test.go — proves the canonical OEE identity (oee == A·P·Q) and that a
// count spike is BOUNDED (never yields oee > 1), on synthetic rows. No DB — the
// golden SQL path needs Postgres + `-tags golden`; this locks the shared algebra
// the reconcile SQL mirrors.
package rollup

import (
	"math"
	"testing"
)

func almostEqual(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestCanonicalOEEIdentityHolds(t *testing.T) {
	cases := []struct {
		name                                      string
		net, gross, running, planned, idealPerMin float64
	}{
		// Healthy shift: 8000 good / 8200 total, ran 25200s of a 28800s window,
		// nominal 20/min. Every factor < 1 — the interesting general case.
		{"healthy", 8000, 8200, 25200, 28800, 20},
		// Quality-limited: lots of scrap.
		{"low-quality", 5000, 9000, 25200, 28800, 20},
		// Availability-limited: ran only a third of the planned window.
		{"low-availability", 3000, 3100, 9600, 28800, 20},
		// COUNT SPIKE: net/gross are ~10× a physically-possible count for the
		// running window (a first-boot / reset totalizer dump). Performance would
		// be ~10 unclamped; the identity must still hold AND oee must stay ≤ 1.
		{"count-spike", 300000, 305000, 25200, 28800, 20},
		// Zero-gross degenerate: Q=0 → oee=0, identity still holds (0==a·0·p).
		{"zero-gross", 0, 0, 25200, 28800, 20},
		// Zero-running degenerate: A=0 and P=0 → oee=0, no divide-by-zero blowup.
		{"zero-running", 8000, 8200, 0, 28800, 20},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			oee, a, p, q := CanonicalOEE(c.net, c.gross, c.running, c.planned, c.idealPerMin)
			// (1) every factor is a genuine [0,1] measurement.
			for name, f := range map[string]float64{"oee": oee, "a": a, "p": p, "q": q} {
				if f < 0 || f > 1 {
					t.Fatalf("%s out of [0,1]: %v", name, f)
				}
			}
			// (2) THE IDENTITY: oee == a·p·q, exactly (the whole point of fault 3).
			if !almostEqual(oee, a*p*q) {
				t.Fatalf("identity broken: oee=%v a·p·q=%v (a=%v p=%v q=%v)", oee, a*p*q, a, p, q)
			}
		})
	}
}

// The count spike must be bounded: even a 10× totalizer dump cannot push OEE
// above 1 (the old top-down LEAST(net/ideal,1) clamped to a FAKE 1.0 while the
// components said otherwise — here the product stays a bounded, honest number).
func TestCanonicalOEESpikeBounded(t *testing.T) {
	oee, a, p, q := CanonicalOEE(300000, 305000, 25200, 28800, 20)
	if oee > 1 {
		t.Fatalf("spike produced oee>1: %v", oee)
	}
	// Performance is the factor that absorbs (and clamps) the spike.
	if p != 1 {
		t.Fatalf("spiked performance should clamp to 1, got %v", p)
	}
	// And the identity still holds under the clamp.
	if !almostEqual(oee, a*p*q) {
		t.Fatalf("identity broken under spike: oee=%v a·p·q=%v", oee, a*p*q)
	}
}

// On CLEAN data the canonical product equals the legacy top-down number
// (net/ideal_production), so flipping the definition changes nothing where no
// factor clamps — it only corrects the clamped/spiked rows. Proves claim (†).
func TestCanonicalMatchesTopDownWhenUnclamped(t *testing.T) {
	net, gross, running, planned, ideal := 8000.0, 8200.0, 25200.0, 28800.0, 20.0
	oee, _, p, _ := CanonicalOEE(net, gross, running, planned, ideal)
	if p >= 1 {
		t.Fatalf("precondition: this case must be unclamped (p<1), got p=%v", p)
	}
	idealProduction := ideal * planned / 60.0
	topDown := net / idealProduction // legacy headline, pre-LEAST
	if !almostEqual(oee, topDown) {
		t.Fatalf("canonical %v != top-down %v on unclamped data", oee, topDown)
	}
}
