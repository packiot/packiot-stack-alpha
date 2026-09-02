// silver_rules_test.go — ADR-0037 "Silver" ingest-side cleaning rules in the
// Calc port: (b) timestamp-monotonicity guard and (f) counter rollover-vs-reset.
//
// The invariant every test here upholds: with the flag OFF (the zero Config /
// plain Calc), behavior is byte-identical to the legacy Node-RED parity path.
// The flag ON changes the delta/reset semantics per the ADR. Each rule has a
// paired OFF/ON test so the gating itself is proven, not just the new logic.

package calc_production_counters

import (
	"testing"
	"time"
)

const srBase = "CPACK/SC/LINHAS/L5/BREYER"
const srConsumed = srBase + "/Admin/ProdConsumedCount/61/Unit"

// applyAll applies every deferred state mutation to s (test helper — the
// production caller does the same in main.go's runShadow loop).
func applyAll(s State, muts []StateMutation) {
	for _, m := range muts {
		_ = m.Apply(s)
	}
}

func consumedMetric(dec Decision) *Metric {
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == srConsumed {
			return &dec.Metrics[i]
		}
	}
	return nil
}

func hasMutationKind(muts []StateMutation, kind string) bool {
	for _, m := range muts {
		if m.Kind == kind {
			return true
		}
	}
	return false
}

// ── ADR-0037 (b): monotonicity guard ──────────────────────────────────────

// A late, reordered redelivery (older ts, smaller value) arriving after a
// newer larger reading is the phantom-production bug: the legacy path misreads
// prev>cur as a reset, then the next legit reading emits full-value-from-zero.
// The guard drops the stale message. This test drives the exact sequence and
// asserts OFF=phantom / ON=clean.
func TestMonotonicityGuard_DropsStaleRedelivery(t *testing.T) {
	newState := func() State {
		s := NewMemState()
		s.SetInt(srConsumed, 90) // last good totalizer reading
		s.SetFloat(srBase+"/Status/MachSpeed", 100000.0)
		s.SetTimeMs(srConsumed+"___LAST_TS", 1700000000000)
		return s
	}
	// Stale message: ts BEFORE the watermark, value BELOW prev (the reorder).
	stale := Message{
		Topic:      srConsumed + "***TRIG",
		Payload:    40,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1699999990000), // older than watermark
	}

	// OFF (legacy): prev(90) > cur(40) → reset path fires, sends downstream.
	sOff := newState()
	decOff, err := CalcWithConfig(stale, sOff, Config{})
	if err != nil {
		t.Fatalf("off: %v", err)
	}
	if !decOff.SendDownstream {
		t.Fatalf("off: expected legacy reset path to send (phantom), got drop")
	}

	// ON: the stale message is dropped as non-monotonic; no reset, no emit.
	sOn := newState()
	decOn, err := CalcWithConfig(stale, sOn, Config{MonotonicityGuard: true})
	if err != nil {
		t.Fatalf("on: %v", err)
	}
	if decOn.SendDownstream {
		t.Errorf("on: stale redelivery should be dropped, got send")
	}
	if got := decOn.EnrichedMsg["skipped_reason"]; got != "non_monotonic_ts" {
		t.Errorf("on: skipped_reason = %v, want non_monotonic_ts", got)
	}
	if len(decOn.StateUpdates) != 0 {
		t.Errorf("on: stale drop must not mutate state (watermark stays), got %+v", decOn.StateUpdates)
	}
}

// An in-order message (ts strictly newer than the watermark) is processed
// normally AND advances the watermark. Flag ON.
func TestMonotonicityGuard_InOrderAdvancesWatermark(t *testing.T) {
	s := NewMemState()
	s.SetInt(srConsumed, 90)
	s.SetFloat(srBase+"/Status/MachSpeed", 100000.0)
	s.SetTimeMs(srConsumed+"___LAST_TS", 1700000000000)

	fresh := Message{
		Topic:      srConsumed + "***TRIG",
		Payload:    95, // +5
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000005000), // newer than watermark
	}
	dec, err := CalcWithConfig(fresh, s, Config{MonotonicityGuard: true})
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("in-order message should send")
	}
	if m := consumedMetric(dec); m == nil || m.Value != 5 {
		t.Fatalf("expected Consumed increment 5, got %+v", m)
	}
	if !hasMutationKind(dec.StateUpdates, "counter.last_ts") {
		t.Errorf("watermark advance mutation (counter.last_ts) missing: %+v", dec.StateUpdates)
	}
	// Watermark actually written forward after applying mutations.
	applyAll(s, dec.StateUpdates)
	if ts, _ := s.TimeMs(srConsumed + "___LAST_TS"); ts != 1700000005000 {
		t.Errorf("watermark = %d, want 1700000005000", ts)
	}
}

// First-ever message (no watermark yet) must be accepted, not dropped.
func TestMonotonicityGuard_FirstMessageAccepted(t *testing.T) {
	s := NewMemState()
	s.SetInt(srConsumed, 0)
	s.SetFloat(srBase+"/Status/MachSpeed", 100000.0)

	msg := Message{
		Topic:      srConsumed + "***TRIG",
		Payload:    10,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := CalcWithConfig(msg, s, Config{MonotonicityGuard: true})
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if got := dec.EnrichedMsg["skipped_reason"]; got == "non_monotonic_ts" {
		t.Fatalf("first message wrongly dropped as non-monotonic")
	}
	if !hasMutationKind(dec.StateUpdates, "counter.last_ts") {
		t.Errorf("first message should seed the watermark: %+v", dec.StateUpdates)
	}
}

// ── ADR-0037 (f): counter rollover vs reset ───────────────────────────────

func newRolloverState(t *testing.T, prev, counterMax int64) State {
	t.Helper()
	s := NewMemState()
	s.SetInt(srConsumed, prev)
	s.SetFloat(srBase+"/Status/MachSpeed", 1e9) // never trip the speed glitch guard
	if counterMax > 0 {
		s.SetInt(srBase+"/Status/CounterMax", counterMax)
	}
	return s
}

func rolloverMsg(cur int64) Message {
	return Message{
		Topic:      srConsumed + "***TRIG",
		Payload:    cur,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
}

// A WIDE per-equipment totalizer near its ceiling (990000/1000000) wraps to a
// small value (100). ON: increment is the rollover delta (1000000-990000)+100 =
// 10100, the counter persists at the new post-wrap reading, and it is NOT a
// reset. OFF: same input rebaselines to 0 → increment 100 (the undercount the
// ADR names). NOTE: the width is deliberately OUTSIDE the staging ADR-0048
// isUint16Rollover band ([61440,65535]→[0,4095], unflagged) so this test
// isolates the ADR-0037 (f) per-equipment counter_max path — a 16-bit wrap
// would already be recovered on staging regardless of the flag.
func TestCounterRollover_WrapVsReset(t *testing.T) {
	const cmax, prev, cur = 1000000, 990000, 100
	const wantRollover = (cmax - prev) + cur // 10100

	// OFF — legacy reset semantics (undercount).
	sOff := newRolloverState(t, prev, cmax)
	decOff, err := CalcWithConfig(rolloverMsg(cur), sOff, Config{})
	if err != nil {
		t.Fatalf("off: %v", err)
	}
	if m := consumedMetric(decOff); m == nil || m.Value != cur {
		t.Fatalf("off: want legacy reset increment %d, got %+v", cur, m)
	}

	// ON — rollover delta recovered.
	sOn := newRolloverState(t, prev, cmax)
	decOn, err := CalcWithConfig(rolloverMsg(cur), sOn, Config{CounterRollover: true})
	if err != nil {
		t.Fatalf("on: %v", err)
	}
	m := consumedMetric(decOn)
	if m == nil {
		t.Fatalf("on: no Consumed metric emitted")
	}
	if m.Value != wantRollover {
		t.Errorf("on: rollover increment = %d, want %d", m.Value, wantRollover)
	}
	if m.Counter != cur {
		t.Errorf("on: persisted counter = %d, want post-wrap %d", m.Counter, cur)
	}
	if !hasCounterUpdate(decOn.StateUpdates, srConsumed, cur) {
		t.Errorf("on: counter should persist at post-wrap %d: %+v", cur, decOn.StateUpdates)
	}
}

// A mid-range prev dropping to a small value is a genuine reset, NOT a wrap —
// even with the flag on and counter_max known. Must take the reset path.
func TestCounterRollover_MidRangeIsReset(t *testing.T) {
	const cmax, prev, cur = 65535, 30000, 100 // prev well below the 90% band
	s := newRolloverState(t, prev, cmax)
	dec, err := CalcWithConfig(rolloverMsg(cur), s, Config{CounterRollover: true})
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if m := consumedMetric(dec); m == nil || m.Value != cur {
		t.Errorf("mid-range reset increment = %+v, want %d (reset, not rollover)", m, cur)
	}
}

// Flag on but no counter_max in refdata → the wrap cannot be proven → reset
// path (byte-identical to off). Prevents guessing a wrap width. prev/cur are
// kept outside the staging 16-bit band so the "off" fallback is a genuine
// reset (increment=cur), not the unflagged ADR-0048 uint16 wrap recovery.
func TestCounterRollover_NoCounterMaxFallsBackToReset(t *testing.T) {
	const prev, cur = 990000, 100
	s := newRolloverState(t, prev, 0) // counter_max unset
	dec, err := CalcWithConfig(rolloverMsg(cur), s, Config{CounterRollover: true})
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if m := consumedMetric(dec); m == nil || m.Value != cur {
		t.Errorf("no-counter_max increment = %+v, want reset %d", m, cur)
	}
}

// Direct unit test of the pure classifier across the band boundaries.
func TestRolloverAdjustedPrev(t *testing.T) {
	const cmax = 1000
	cases := []struct {
		name           string
		prev, cur      int64
		cfg            Config
		wantPrev       int64
		wantIsRollover bool
	}{
		{"flag off => reset", 990, 5, Config{}, 0, false},
		{"wrap in band", 990, 5, Config{CounterRollover: true}, 990 - cmax, true},
		{"prev below high band => reset", 800, 5, Config{CounterRollover: true}, 0, false},
		{"cur above low band => reset", 990, 200, Config{CounterRollover: true}, 0, false},
		{"exact band edges => rollover", 900, 100, Config{CounterRollover: true}, 900 - cmax, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotPrev, gotRoll := rolloverAdjustedPrev(tc.prev, tc.cur, cmax, tc.cfg)
			if gotPrev != tc.wantPrev || gotRoll != tc.wantIsRollover {
				t.Errorf("rolloverAdjustedPrev(%d,%d) = (%d,%v), want (%d,%v)",
					tc.prev, tc.cur, gotPrev, gotRoll, tc.wantPrev, tc.wantIsRollover)
			}
		})
	}
}

// counter_max == 0 must never divide/underflow and always yields reset.
func TestRolloverAdjustedPrev_ZeroMaxSafe(t *testing.T) {
	if p, r := rolloverAdjustedPrev(500, 1, 0, Config{CounterRollover: true}); p != 0 || r {
		t.Errorf("zero counter_max: got (%d,%v), want (0,false)", p, r)
	}
}
