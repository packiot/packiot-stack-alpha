package calc_production_counters

import (
	"testing"
	"time"
)

func TestTrackedStateDirtyCycle(t *testing.T) {
	ts := NewTrackedState(NewMemState())
	_ = ts.SetInt("c", 10)
	_ = ts.SetInt("c", 12) // last value wins
	_ = ts.SetFloat("f", 1.5)
	_ = ts.SetTimeMs("t", 99)
	_ = ts.SetBool("b", true) // config — not tracked
	got := ts.TakeDirty()
	want := []StateEntry{
		{Kind: StateEntryFloat, Key: "f", Float: 1.5},
		{Kind: StateEntryInt, Key: "c", Int: 12},
		{Kind: StateEntryTimeMs, Key: "t", Int: 99},
	}
	if len(got) != len(want) {
		t.Fatalf("TakeDirty = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("TakeDirty[%d] = %+v, want %+v", i, got[i], want[i])
		}
	}
	if again := ts.TakeDirty(); len(again) != 0 {
		t.Fatalf("second TakeDirty = %+v, want empty", again)
	}
	ts.Requeue(got[:1])
	if rq := ts.TakeDirty(); len(rq) != 1 || rq[0].Key != "f" {
		t.Fatalf("after Requeue = %+v", rq)
	}
}

func TestTrackedStateRestoreIsNotDirty(t *testing.T) {
	ts := NewTrackedState(NewMemState())
	n, err := ts.Restore([]StateEntry{
		{Kind: StateEntryInt, Key: "c", Int: 1026},
		{Kind: StateEntryTimeMs, Key: "t", Int: 5},
		{Kind: "bogus", Key: "x"},
	})
	if err != nil || n != 2 {
		t.Fatalf("Restore = %d, %v", n, err)
	}
	if v, ok := ts.Int("c"); !ok || v != 1026 {
		t.Fatalf("Int(c) = %d, %v", v, ok)
	}
	if d := ts.TakeDirty(); len(d) != 0 {
		t.Fatalf("restored keys must not be dirty: %+v", d)
	}
}

// The core property: a Calc process restored from a checkpoint differences the
// next reading against the last EMITTED counter, so Σ increments across a
// restart equals the counter movement. Without restore the first post-restart
// reading is a first-observation seed and its delta is lost.
func TestRestartWithRestoredBaselineLosesNothing(t *testing.T) {
	topic := "BISPHARMA/SITE/AREA/L1/M1/Admin/ProdConsumedCount/1/Unit"
	run := func(st State, vals []int64, t0 int64) int64 {
		var sum int64
		for i, v := range vals {
			msg := Message{Topic: topic + "***TRIG", Payload: v, CmdTrigger: true, ResetHeal: true, NoSpeedGuardFallback: true}
			msg.Timestamp = time.UnixMilli(1_790_000_000_000 + t0 + int64(i)*12000)
			dec, err := Calc(msg, st)
			if err != nil {
				t.Fatal(err)
			}
			for _, m := range dec.StateUpdates {
				_ = m.Apply(st)
			}
			for _, m := range dec.Metrics {
				if m.Name == topic {
					sum += m.Value
				}
			}
		}
		return sum
	}
	before := []int64{1000, 1013, 1026}
	after := []int64{1042, 1055}

	// Restart WITHOUT checkpoint (the pre-fix behavior): 1042 is re-seeded.
	a := NewTrackedState(NewMemState())
	lost := run(a, before, 0) + run(NewMemState(), after, 36000)
	if lost != 26+13 {
		t.Fatalf("pre-fix control: Σ=%d, want 39 (one 16-unit delta lost)", lost)
	}

	// Restart WITH checkpoint restore.
	b := NewTrackedState(NewMemState())
	sum := run(b, before, 0)
	ckpt := b.TakeDirty()
	b2 := NewTrackedState(NewMemState())
	if _, err := b2.Restore(ckpt); err != nil {
		t.Fatal(err)
	}
	sum += run(b2, after, 36000)
	if sum != 1055-1000 {
		t.Fatalf("Σ increments across restart = %d, want counter movement %d", sum, 1055-1000)
	}
}
