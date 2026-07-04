package reconcile

import "testing"

// The oscillator guard's cap must stay far above real deltas and far
// below the poison scale (e38 incident, e11 seeds).
func TestDeltaSanityCap(t *testing.T) {
	if deltaSanityCap < 1e6 || deltaSanityCap > 1e12 {
		t.Fatalf("cap %v outside sane band", deltaSanityCap)
	}
}
