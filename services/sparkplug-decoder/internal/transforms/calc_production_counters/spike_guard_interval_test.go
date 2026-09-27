package calc_production_counters

import (
	"testing"
	"time"
)

// CPACK L6-TEXA publishes Consumed and Processed in SEPARATE messages ~0.6 s
// apart, every 15 s. The WS1 spike guard used the time since the unit's last
// CurMachSpeed update as its window; the Consumed message refreshes that, so the
// Processed message got a 0.576 s window: ceiling = 10 × 146/min × 0.576 s ≈ 14,
// and every net increment of ~37 was clamped to 14 (net fell to ~half of legacy
// from 2026-09-23). The window must be the gap since the counter's OWN previous
// reading (15 s here), so a normal 37 passes untouched.
func TestSpikeGuardUsesOwnCounterInterval(t *testing.T) {
	s := NewMemState()
	base := "CPACK/SC/LINHAS/L6/TEXA"
	s.SetFloat(base+"/Status/MachSpeed", 100.0)
	cons := base + "/Admin/ProdConsumedCount/92/Unit***TRIG"
	proc := base + "/Admin/ProdProcessedCount/92/Unit***TRIG"
	const t0 = int64(1700000000000)

	run := func(topic string, v int64, ts int64) Decision {
		t.Helper()
		dec, err := Calc(Message{
			Topic: topic, Payload: v, CmdTrigger: true, Timestamp: time.UnixMilli(ts),
			GuardRatedSpeed: 146, CounterSpikeMargin: 10,
		}, s)
		if err != nil {
			t.Fatalf("Calc(%s): %v", topic, err)
		}
		for _, m := range dec.StateUpdates {
			if err := m.Apply(s); err != nil {
				t.Fatalf("apply: %v", err)
			}
		}
		return dec
	}
	metric := func(dec Decision, name string) *Metric {
		for i := range dec.Metrics {
			if dec.Metrics[i].Name == name {
				return &dec.Metrics[i]
			}
		}
		return nil
	}

	// first observations seed both streams
	run(cons, 270306900, t0)
	run(proc, 270306900, t0+576)

	// one normal 15 s cycle: +37 on each counter, Processed 576 ms after Consumed
	c := run(cons, 270306937, t0+15000)
	p := run(proc, 270306937, t0+15576)

	if m := metric(c, base+"/Admin/ProdConsumedCount/92/Unit"); m == nil || m.Value != 37 {
		t.Fatalf("consumed increment = %+v, want 37", m)
	}
	m := metric(p, base+"/Admin/ProdProcessedCount/92/Unit")
	if m == nil {
		t.Fatalf("processed emitted no metric")
	}
	if m.Value != 37 {
		t.Errorf("processed increment = %d, want 37 (the guard window must be the counter's own 15 s gap, not 0.576 s since the Consumed message)", m.Value)
	}

	// a real spike is still bounded: +5000 in 15 s never passes through (the WS1
	// ceiling is 10×146×15/60 = 365; the older speed-glitch guard may drop it first)
	c2 := run(cons, 270311937, t0+30000)
	if m := metric(c2, base+"/Admin/ProdConsumedCount/92/Unit"); m != nil && m.Value > 365 {
		t.Errorf("spike increment = %d, want dropped or clamped to <= 365", m.Value)
	}
}
