package calc_production_counters

import (
	"testing"
	"time"
)

// Unsigned-16-bit counter read through a signed S7 INT (CPACK L8-PTH/L10-PTH,
// DB1,INT32). The PLC register counts 0..65535 and wraps; the edge reads it as
// int16, so the upper half arrives as -32768..-1. These tests drive the real
// sequence through CalcWithConfig with the staging flags (NoSpeedGuardFallback +
// ResetHeal on — both machines report no MachSpeed) and apply every state
// mutation between ticks, exactly like cmd/edge-transformer's runShadow.

// pthTick builds one L10-PTH consumed-counter message 15 s apart.
func pthTick(payload int64, i int, uint16Counter bool) Message {
	return Message{
		Topic:                l10PthConsumed + "***TRIG",
		Payload:              payload,
		Timestamp:            time.UnixMilli(1_790_000_000_000 + int64(i)*15_000),
		Tenant:               "cpack",
		CmdTrigger:           true,
		NoSpeedGuardFallback: true,
		ResetHeal:            true,
		Uint16Counter:        uint16Counter,
	}
}

// runPTHSequence feeds the raw (signed) reads in order and returns the emitted
// consumed increment per tick (0 = nothing emitted for that tick).
func runPTHSequence(t *testing.T, raw []int64, uint16Counter bool) []int64 {
	t.Helper()
	s := NewMemState()
	got := make([]int64, len(raw))
	for i, v := range raw {
		dec, err := CalcWithConfig(pthTick(v, i, uint16Counter), s, Config{})
		if err != nil {
			t.Fatalf("tick %d (%d): %v", i, v, err)
		}
		for _, m := range dec.Metrics {
			if m.Name == l10PthConsumed {
				got[i] = m.Value
			}
		}
		applyAll(s, dec.StateUpdates)
	}
	return got
}

func sum(xs []int64) (n int64) {
	for _, x := range xs {
		n += x
	}
	return n
}

// The signed reads 32000 → 32767 → -32768 → -1 → 5 are the unsigned register
// 32000 → 32767 → 32768 → 65535 → (wrap) 5. True production after the seed:
// 767 + 1 + 32767 + 6 = 33541.
var pthSignedReads = []int64{32000, 32767, -32768, -1, 5}

func TestUint16Counter_SignedReadAccumulatesAcrossWrap(t *testing.T) {
	got := runPTHSequence(t, pthSignedReads, true)
	want := []int64{0 /* first-obs seed */, 767, 1, 32767, 6}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("tick %d (raw %d): increment = %d, want %d", i, pthSignedReads[i], got[i], want[i])
		}
	}
	if s := sum(got); s != 33541 {
		t.Errorf("total production = %d, want 33541", s)
	}
}

// Pins the bug on the unflagged (pre-fix) path: every tick above 32767 is
// dropped. The only credit after the drop is the post-wrap 5 differenced from
// a 0 baseline — 772 of 33541 counts survive (~98% lost on this sample).
func TestUint16Counter_UnflaggedLosesUpperHalf(t *testing.T) {
	got := runPTHSequence(t, pthSignedReads, false)
	want := []int64{0, 767, 0, 0, 5}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("tick %d (raw %d): increment = %d, want %d (legacy loss pattern)", i, pthSignedReads[i], got[i], want[i])
		}
	}
}

// A first observation that lands in the upper half seeds the TRUE unsigned
// baseline (not the clamped 0), so the next tick differences correctly
// instead of emitting a ~40k phantom from zero.
func TestUint16Counter_FirstObservationInUpperHalfSeedsUnsigned(t *testing.T) {
	got := runPTHSequence(t, []int64{-25536 /* 40000 */, -25500 /* 40036 */}, true)
	if got[0] != 0 || got[1] != 36 {
		t.Fatalf("increments = %v, want [0 36]", got)
	}
}

// A genuine factory reset from the upper half (40000 → 12) is still a reset:
// the flag changes only the representation, not the reset/wrap classifier.
func TestUint16Counter_MidRangeDropStillResets(t *testing.T) {
	got := runPTHSequence(t, []int64{-25536, -25500, 12, 20}, true)
	want := []int64{0, 36, 0 /* reset-heal reseed */, 8}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("tick %d: increment = %d, want %d", i, got[i], want[i])
		}
	}
}

func TestNormalizeUint16(t *testing.T) {
	cases := []struct {
		in, want int64
		changed  bool
	}{
		{-32768, 32768, true},
		{-1, 65535, true},
		{0, 0, false},
		{32767, 32767, false},
		{-32769, -32769, false}, // outside int16: not a signed 16-bit read
		{-900000, -900000, false},
	}
	for _, c := range cases {
		got, ok := normalizeUint16(c.in)
		if got != c.want || ok != c.changed {
			t.Errorf("normalizeUint16(%d) = (%d,%v), want (%d,%v)", c.in, got, ok, c.want, c.changed)
		}
	}
}
