package calc_production_counters

import (
	"testing"
	"time"
)

// Counters-only OEE mode tests.
//
// Validation case: CPACK L6 (enterprise C-PACK, staging ent 3) — a Modbus
// counters-only line whose live tee confirms SPEED:NO (only ProdProcessed /
// ProdConsumed / ProdDefectiveCount, no MachSpeed). Real prod config for L6
// and every member machine (BREYER/TEXA/POLYTYPE/RMH/PTH, id_equipment 90-95):
//
//	equipments.production_speed = 147   (uniform, line + members)
//	equipments.ideal_speed      = NULL  (never set)
//
// So 147 parts/min is the configured rated speed we seed as IdealRate.
const (
	l6BreyerBase   = "C-PACK/SC/LINHAS/L6/BREYER"
	l6ConsumedTop  = l6BreyerBase + "/Admin/ProdConsumedCount/91/Unit"
	l6ProcessedTop = l6BreyerBase + "/Admin/ProdProcessedCount/91/Unit"
	l6RatedSpeed   = 147.0 // equipments.production_speed for CPACK L6 (prod)
)

// counterTick builds a Consumed-counter trigger message for L6 BREYER at
// timestampMs with the given cumulative counter value, optionally in
// counters-only mode.
func l6ConsumedTick(payload int64, timestampMs int64, countersOnly bool, idealRate float64) Message {
	return Message{
		Topic:        l6ConsumedTop + "***TRIG",
		Payload:      payload,
		Timestamp:    time.UnixMilli(timestampMs),
		Tenant:       "cpack",
		CmdTrigger:   true,
		CountersOnly: countersOnly,
		IdealRate:    idealRate,
	}
}

// seedL6Prior sets prior counters + a prior speed timestamp so computeSpeed
// yields a non-zero derived count-rate on the next tick. Deliberately does
// NOT seed MachSpeed — that is the whole point of the counters-only class.
func seedL6Prior(s State, priorCount int64, priorTsMs int64) {
	s.SetInt(l6ConsumedTop, priorCount)
	s.SetInt(l6ProcessedTop, priorCount)
	// Prior speed sample timestamp → computeSpeed can difference against it.
	s.SetTimeMs(l6BreyerBase+"/Status/CurMachSpeed___TS", priorTsMs)
}

// TestCountersOnly_BugRepro_MachSpeedZeroRejectsAllCounts pins the failing
// behavior the feature fixes: with counters-only mode OFF and no MachSpeed
// seeded, Phase 8's guard bound is 3*machSpeed = 0, so a perfectly valid
// count increment is REJECTED and nothing is emitted → zero OEE downstream.
func TestCountersOnly_BugRepro_MachSpeedZeroRejectsAllCounts(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedL6Prior(s, 1000, now-60000) // 60s earlier

	// +50 consumed over 60s → derived rate 50/min. No MachSpeed seeded.
	msg := l6ConsumedTick(1050, now, false /*countersOnly*/, 0)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if dec.SendDownstream {
		t.Fatalf("SendDownstream: got true, want false — the pre-fix bug rejects every counter when machSpeed=0")
	}
	if len(dec.Metrics) != 0 {
		t.Fatalf("Metrics: got %d, want 0 (all counts rejected by 3*machSpeed=0 guard)", len(dec.Metrics))
	}
}

// TestCountersOnly_EmitsWhenEnabled proves the fix: same input, but with
// counters-only mode ON and the configured rated speed (147) supplied, the
// count is accepted, a Consumed metric is emitted with the derived count-rate
// as curspeed, and SendDownstream flips true. The emitted rate divided by the
// ideal rate is the (sane, <1) Performance the rollup will compute.
func TestCountersOnly_EmitsWhenEnabled(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedL6Prior(s, 1000, now-60000)

	msg := l6ConsumedTick(1050, now, true /*countersOnly*/, l6RatedSpeed)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true — counters-only mode must accept the count")
	}

	var consumed *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == l6ConsumedTop {
			consumed = &dec.Metrics[i]
			break
		}
	}
	if consumed == nil {
		t.Fatalf("no Consumed metric emitted; got %d metrics: %+v", len(dec.Metrics), dec.Metrics)
	}
	if consumed.Value != 50 {
		t.Errorf("Consumed.Value (increment): got %d, want 50", consumed.Value)
	}
	if consumed.Counter != 1050 {
		t.Errorf("Consumed.Counter: got %d, want 1050", consumed.Counter)
	}

	// Derived count-rate: (50 counts / 60000 ms) * 60000 = 50 parts/min.
	const wantRate = 50.0
	if consumed.CurSpeed != wantRate {
		t.Errorf("Consumed.CurSpeed (derived count-rate): got %v, want %v", consumed.CurSpeed, wantRate)
	}

	// The enrichment records the mode + ideal rate for observability.
	if got := dec.EnrichedMsg["counters_only_mode"]; got != true {
		t.Errorf("EnrichedMsg[counters_only_mode]: got %v, want true", got)
	}
	if got := dec.EnrichedMsg["ideal_rate"]; got != l6RatedSpeed {
		t.Errorf("EnrichedMsg[ideal_rate]: got %v, want %v", got, l6RatedSpeed)
	}

	// Performance the rollup would compute = count-rate / ideal-rate.
	// This is measured against the CONFIGURED speed (147), NOT a speed
	// derived from the same counts, so it is a real number < 1 (not the
	// circular ~100% a self-derived speed would give).
	performance := wantRate / l6RatedSpeed
	if performance <= 0 || performance >= 1 {
		t.Errorf("counters-only Performance = %.3f; want a sane 0<P<1 for a rate below rated speed", performance)
	}
}

// TestCountersOnly_GuardStillRejectsGlitch confirms the swapped guard is still
// a guard: a derived rate above K*ideal (3*147=441/min) is a counter glitch
// and must be rejected even in counters-only mode.
func TestCountersOnly_GuardStillRejectsGlitch(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedL6Prior(s, 1000, now-60000)

	// +30000 consumed over 60s → 30000/min ≫ 3*147=441 → glitch.
	msg := l6ConsumedTick(31000, now, true, l6RatedSpeed)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	for _, m := range dec.Metrics {
		if m.Name == l6ConsumedTop {
			t.Fatalf("glitch rate accepted: emitted Consumed metric %+v; the rated-speed guard should reject it", m)
		}
	}
}

// TestCountersOnly_AutoDeselectWhenSpeedPresent proves mode auto-selection:
// even when the equipment is opted in (CountersOnly=true, IdealRate set), a
// machine that DOES report MachSpeed keeps the original 3*machSpeed guard —
// the ideal-rate bound only kicks in when machSpeed is absent (0). This keeps
// mixed fleets safe: opting a line in never changes a speed-sensing machine.
func TestCountersOnly_AutoDeselectWhenSpeedPresent(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedL6Prior(s, 1000, now-60000)
	s.SetFloat(l6BreyerBase+"/Status/MachSpeed", 100.0) // real speed sensor

	msg := l6ConsumedTick(1050, now, true, l6RatedSpeed)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	// machSpeed=100 → bound 300; derived rate 50 < 300 → still accepted, but
	// via the ORIGINAL guard. The counters-only enrichment must be absent.
	if got, ok := dec.EnrichedMsg["counters_only_mode"]; ok {
		t.Errorf("counters_only_mode enrichment present (%v) despite machSpeed>0; auto-select should keep the machSpeed guard", got)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true (rate 50 < 3*100)")
	}
}

// TestCountersOnly_FlagOffParity is the flag-off parity guard: with
// CountersOnly=false the new fields are never consulted, so the outcome is
// identical to a machine with no MachSpeed under the original code — every
// count rejected. Any future edit that leaks counters-only behavior into the
// flag-off path fails here.
func TestCountersOnly_FlagOffParity(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedL6Prior(s, 1000, now-60000)

	// IdealRate is set but CountersOnly=false → must be ignored.
	msg := l6ConsumedTick(1050, now, false, l6RatedSpeed)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if dec.SendDownstream || len(dec.Metrics) != 0 {
		t.Fatalf("flag-off leaked counters-only behavior: SendDownstream=%v metrics=%d", dec.SendDownstream, len(dec.Metrics))
	}
	if _, ok := dec.EnrichedMsg["counters_only_mode"]; ok {
		t.Errorf("counters_only_mode enrichment set with CountersOnly=false")
	}
}
