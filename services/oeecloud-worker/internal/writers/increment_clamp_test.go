package writers

import (
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// newTestClamp builds an enabled clamp with the eq-57 profile: rated speed
// 147/min, K=4, Δt floor 60s (bound floor = 4·147·1min = 588).
func newTestClamp() *incrementClamp {
	return &incrementClamp{k: 4.0, minDt: 60 * time.Second, last: make(map[clampKey]int64)}
}

const t0 = int64(1_700_000_000_000) // fixed base ms

// The canonical phantom: after a normal baseline sample, a publisher switch
// mints an ≈828k increment a few seconds later. Δt (5s) floors to 60s →
// bound 588 → clamped to 0 with an event carrying the rejected magnitude.
func TestClamp_PhantomRejected(t *testing.T) {
	c := newTestClamp()
	const proc = sparkplug.KindProdProcessedCount

	if v, ev := c.eval(57, 1, proc, t0, 147, 100); v != 100 || ev != nil {
		t.Fatalf("baseline: got (%v,%v), want (100,nil)", v, ev)
	}
	v, ev := c.eval(57, 1, proc, t0+5_000, 147, 828_000)
	if v != 0 || ev == nil {
		t.Fatalf("phantom: got (%v,%v), want (0, event)", v, ev)
	}
	if ev.Observed != 828_000 {
		t.Errorf("Observed = %v, want 828000", ev.Observed)
	}
	if ev.Bound != 588 {
		t.Errorf("Bound = %v, want 588 (4*147*1min floor)", ev.Bound)
	}
	if ev.IDEquipment != 57 || ev.IDEnterprise != 1 || ev.Kind != proc {
		t.Errorf("event identity wrong: %+v", ev)
	}
	if want := time.UnixMilli(t0 + 5_000).Truncate(time.Second).UTC(); !ev.BucketTS.Equal(want) {
		t.Errorf("BucketTS = %v, want %v", ev.BucketTS, want)
	}
}

// A genuinely large increment over a genuinely long gap is NOT a phantom:
// Δt-awareness scales the bound so real production passes.
func TestClamp_LegitLargeOverLongGapPasses(t *testing.T) {
	c := newTestClamp()
	const proc = sparkplug.KindProdProcessedCount
	c.eval(57, 1, proc, t0, 147, 100) // baseline
	// 5 min gap → bound = 4*147*5 = 2940. 700 real parts pass.
	if v, ev := c.eval(57, 1, proc, t0+300_000, 147, 700); v != 700 || ev != nil {
		t.Fatalf("legit: got (%v,%v), want (700,nil)", v, ev)
	}
}

// A sub-interval burst must not false-positive: the Δt floor keeps the bound
// at 588 rather than collapsing toward zero for a 2s gap.
func TestClamp_SubIntervalBurstFloored(t *testing.T) {
	c := newTestClamp()
	const proc = sparkplug.KindProdProcessedCount
	c.eval(57, 1, proc, t0, 147, 100)
	if v, ev := c.eval(57, 1, proc, t0+2_000, 147, 10); v != 10 || ev != nil {
		t.Fatalf("burst: got (%v,%v), want (10,nil) — floor must protect legit counts", v, ev)
	}
}

func TestClamp_FailOpenNoRatedSpeed(t *testing.T) {
	c := newTestClamp()
	if v, ev := c.eval(57, 1, sparkplug.KindProdProcessedCount, t0, 0, 999_999); v != 999_999 || ev != nil {
		t.Fatalf("no rate must fail open: got (%v,%v)", v, ev)
	}
}

func TestClamp_FirstSampleFailsOpen(t *testing.T) {
	c := newTestClamp()
	// No prior Δt on this stream → even an implausible value passes once.
	if v, ev := c.eval(57, 1, sparkplug.KindProdProcessedCount, t0, 147, 828_000); v != 828_000 || ev != nil {
		t.Fatalf("first sample must fail open: got (%v,%v)", v, ev)
	}
}

func TestClamp_OutOfOrderFailsOpen(t *testing.T) {
	c := newTestClamp()
	const proc = sparkplug.KindProdProcessedCount
	c.eval(57, 1, proc, t0+60_000, 147, 100) // establish a NEWER clock
	// An older sample: Δt<0 → fail open AND the clock must not rewind.
	if v, ev := c.eval(57, 1, proc, t0, 147, 828_000); v != 828_000 || ev != nil {
		t.Fatalf("out-of-order must fail open: got (%v,%v)", v, ev)
	}
	// Clock stayed at the newer ts: a fresh phantom 5s after it is clamped.
	if v, ev := c.eval(57, 1, proc, t0+65_000, 147, 828_000); v != 0 || ev == nil {
		t.Fatalf("clock must not have rewound: got (%v,%v)", v, ev)
	}
}

func TestClamp_NonPositivePasses(t *testing.T) {
	c := newTestClamp()
	const proc = sparkplug.KindProdProcessedCount
	for _, val := range []float64{0, -5, -828_000} {
		if v, ev := c.eval(57, 1, proc, t0, 147, val); v != val || ev != nil {
			t.Fatalf("non-positive %v must pass: got (%v,%v)", val, v, ev)
		}
	}
}

// Processed/Consumed/Defective are independent streams: a baseline on one
// must not supply the "last reading" for another arriving at the same ts.
func TestClamp_PerKindStreamsIndependent(t *testing.T) {
	c := newTestClamp()
	// Baselines for two kinds at the same ts.
	c.eval(57, 1, sparkplug.KindProdProcessedCount, t0, 147, 100)
	if v, ev := c.eval(57, 1, sparkplug.KindProdConsumedCount, t0, 147, 100); v != 100 || ev != nil {
		t.Fatalf("consumed baseline must be its own first sample: got (%v,%v)", v, ev)
	}
	// A phantom on EACH stream 5s later is clamped independently.
	if v, _ := c.eval(57, 1, sparkplug.KindProdProcessedCount, t0+5_000, 147, 828_000); v != 0 {
		t.Errorf("processed phantom not clamped")
	}
	if v, _ := c.eval(57, 1, sparkplug.KindProdConsumedCount, t0+5_000, 147, 828_000); v != 0 {
		t.Errorf("consumed phantom not clamped")
	}
}

// Flag-off wiring: SetIncrementClamp(false,…) leaves the clamp nil so Build's
// `if w.clamp != nil` guard is skipped entirely — the byte-identical path.
func TestSetIncrementClamp_DisabledIsNil(t *testing.T) {
	w := &EquipmentValues{}
	w.SetIncrementClamp(false, 4, 60)
	if w.clamp != nil {
		t.Fatal("disabled clamp must leave w.clamp nil (flag-off parity)")
	}
	w.SetIncrementClamp(true, 0, 0) // zero args must default, not divide-by-zero
	if w.clamp == nil || w.clamp.k != 4.0 || w.clamp.minDt != 60*time.Second {
		t.Fatalf("enabled clamp defaults wrong: %+v", w.clamp)
	}
}
