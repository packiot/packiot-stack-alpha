package calc_production_counters

import (
	"testing"
	"time"
)

// No-speed guard fallback tests (ADR-0049 count-loss guard).
//
// Validation case: CPACK L10 (staging ent 3) — a Modbus counters-only LINE
// whose members report NO MachSpeed and which is ABSENT from the counters-only
// COUNTERS_ONLY_IDEAL_RATES allowlist (only L6 + L5/TEXA were hand-listed). So
// Phase 8's `prodSpeed < 3*machSpeed` bound is 0 and every count is dropped.
// L10 only ever produced equipment_values because the now-retired
// mirror-worker-go synthesized them; it froze on 2026-08-13 when that retired.
//
// The member machines emit a MIX of counter roles:
//   - L10/DXL  → ProdProcessedCount (net/outfeed) ONLY  (id_equipment 77)
//   - L10/PTH  → ProdConsumedCount  (gross/infeed) ONLY  (id_equipment 78)
//
// Both freeze under the 3*machSpeed=0 guard — proving the drop is NOT keyed on
// the metric's English name (a Consumed machine on the same line dies too), but
// on the absent speed reference. The fallback rescues BOTH.
const (
	l10DxlBase      = "CPACK/SC/LINHAS/L10/DXL"
	l10DxlProcessed = l10DxlBase + "/Admin/ProdProcessedCount/564/Unit"
	l10PthBase      = "CPACK/SC/LINHAS/L10/PTH"
	l10PthConsumed  = l10PthBase + "/Admin/ProdConsumedCount/565/Unit"
)

func l10ProcessedTick(payload, timestampMs int64, fallback bool) Message {
	return Message{
		Topic:                l10DxlProcessed + "***TRIG",
		Payload:              payload,
		Timestamp:            time.UnixMilli(timestampMs),
		Tenant:               "cpack",
		CmdTrigger:           true,
		NoSpeedGuardFallback: fallback,
	}
}

func l10ConsumedTick(payload, timestampMs int64, fallback bool) Message {
	return Message{
		Topic:                l10PthConsumed + "***TRIG",
		Payload:              payload,
		Timestamp:            time.UnixMilli(timestampMs),
		Tenant:               "cpack",
		CmdTrigger:           true,
		NoSpeedGuardFallback: fallback,
	}
}

// seedProcessedPrior primes the Processed baseline (and a speed-sample ts) so
// the next tick differences a real delta rather than hitting the ADR-0045 P1
// first-observation seed (which would drop the sample regardless of the guard).
func seedProcessedPrior(s State, base string, processedTop string, prior, priorTsMs int64) {
	s.SetInt(processedTop, prior)
	s.SetTimeMs(base+"/Status/CurMachSpeed___TS", priorTsMs)
}

func seedConsumedPrior(s State, base, consumedTop string, prior, priorTsMs int64) {
	s.SetInt(consumedTop, prior)
	s.SetTimeMs(base+"/Status/CurMachSpeed___TS", priorTsMs)
}

// TestNoSpeedGuard_BugRepro_ProcessedOnlyDropped pins the freeze: a valid
// ProdProcessedCount increment on a no-MachSpeed machine that is NOT counters-
// only opted in is REJECTED (bound 3*machSpeed = 0), so nothing is emitted.
func TestNoSpeedGuard_BugRepro_ProcessedOnlyDropped(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedProcessedPrior(s, l10DxlBase, l10DxlProcessed, 1000, now-60000)

	msg := l10ProcessedTick(1050, now, false /*fallback*/)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if dec.SendDownstream || len(dec.Metrics) != 0 {
		t.Fatalf("pre-fix bug not reproduced: SendDownstream=%v metrics=%d (want dropped by 3*machSpeed=0 guard)",
			dec.SendDownstream, len(dec.Metrics))
	}
}

// TestNoSpeedGuard_BugRepro_ConsumedOnlyAlsoDropped proves the drop is NOT
// name-based: a ProdConsumedCount machine on the same line, with no MachSpeed
// and no ideal rate, is dropped identically. (prodSpeed>0 here, but the bound
// is still 0, so prodSpeed<0 is false.)
func TestNoSpeedGuard_BugRepro_ConsumedOnlyAlsoDropped(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedConsumedPrior(s, l10PthBase, l10PthConsumed, 1000, now-60000)

	msg := l10ConsumedTick(1050, now, false)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if dec.SendDownstream || len(dec.Metrics) != 0 {
		t.Fatalf("Consumed machine survived the machSpeed=0 guard: SendDownstream=%v metrics=%d — drop is not name-based",
			dec.SendDownstream, len(dec.Metrics))
	}
}

// TestNoSpeedGuard_EmitsProcessedWhenEnabled proves the fix for a Processed-only
// machine: with the fallback ON, the count is accepted and a ProdProcessedCount
// metric is emitted with the correct increment/counter.
func TestNoSpeedGuard_EmitsProcessedWhenEnabled(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedProcessedPrior(s, l10DxlBase, l10DxlProcessed, 1000, now-60000)

	msg := l10ProcessedTick(1050, now, true /*fallback*/)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true — fallback must accept the count")
	}
	var processed *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == l10DxlProcessed {
			processed = &dec.Metrics[i]
			break
		}
	}
	if processed == nil {
		t.Fatalf("no Processed metric emitted; got %d metrics: %+v", len(dec.Metrics), dec.Metrics)
	}
	if processed.Value != 50 {
		t.Errorf("Processed.Value (increment): got %d, want 50", processed.Value)
	}
	if processed.Counter != 1050 {
		t.Errorf("Processed.Counter: got %d, want 1050", processed.Counter)
	}
	if got := dec.EnrichedMsg["no_speed_guard_fallback"]; got != true {
		t.Errorf("EnrichedMsg[no_speed_guard_fallback]: got %v, want true", got)
	}
}

// TestNoSpeedGuard_EmitsConsumedWhenEnabled proves the fix for a Consumed-only
// machine on the same line.
func TestNoSpeedGuard_EmitsConsumedWhenEnabled(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedConsumedPrior(s, l10PthBase, l10PthConsumed, 1000, now-60000)

	msg := l10ConsumedTick(1050, now, true)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true — fallback must accept the count")
	}
	var consumed *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == l10PthConsumed {
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
}

// TestNoSpeedGuard_FlagOffParity is the flag-off parity guard: with the
// fallback false the new field is never consulted, so a no-MachSpeed machine
// stays dropped — byte-identical to the legacy 3*machSpeed=0 guard.
func TestNoSpeedGuard_FlagOffParity(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedProcessedPrior(s, l10DxlBase, l10DxlProcessed, 1000, now-60000)

	msg := l10ProcessedTick(1050, now, false)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if dec.SendDownstream || len(dec.Metrics) != 0 {
		t.Fatalf("flag-off leaked fallback behavior: SendDownstream=%v metrics=%d", dec.SendDownstream, len(dec.Metrics))
	}
	if _, ok := dec.EnrichedMsg["no_speed_guard_fallback"]; ok {
		t.Errorf("no_speed_guard_fallback enrichment set with the flag off")
	}
}

// TestNoSpeedGuard_MachSpeedPresentKeepsGuard proves the fallback does NOT
// weaken a machine that DOES report MachSpeed: the real 3*machSpeed bound stays
// in force even with the flag on, so a genuine glitch is still rejected.
func TestNoSpeedGuard_MachSpeedPresentKeepsGuard(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedConsumedPrior(s, l10PthBase, l10PthConsumed, 1000, now-60000)
	s.SetFloat(l10PthBase+"/Status/MachSpeed", 10.0) // real speed sensor → bound 30

	// +30000 over 60s → 30000/min ≫ 3*10=30 → glitch that MUST still be rejected.
	msg := l10ConsumedTick(31000, now, true /*fallback on*/)

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	for _, m := range dec.Metrics {
		if m.Name == l10PthConsumed {
			t.Fatalf("glitch accepted despite MachSpeed=10 present: %+v — fallback must not override a real bound", m)
		}
	}
	if _, ok := dec.EnrichedMsg["no_speed_guard_fallback"]; ok {
		t.Errorf("no_speed_guard_fallback enrichment set despite machSpeed>0; fallback must only apply when machSpeed==0")
	}
}

// TestNoSpeedGuard_CountersOnlyWinsOverFallback proves precedence: when a
// machine is BOTH counters-only opted in (IdealRate set) and the fallback is
// on, the counters-only rated-speed bound (3*IdealRate) applies — the fallback
// does not blindly disable the guard. A glitch above 3*IdealRate is rejected.
func TestNoSpeedGuard_CountersOnlyWinsOverFallback(t *testing.T) {
	s := NewMemState()
	now := int64(1700000000000)
	seedConsumedPrior(s, l6BreyerBase, l6ConsumedTop, 1000, now-60000)

	msg := l6ConsumedTick(31000, now, true /*countersOnly*/, l6RatedSpeed)
	msg.NoSpeedGuardFallback = true // both on

	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	for _, m := range dec.Metrics {
		if m.Name == l6ConsumedTop {
			t.Fatalf("glitch accepted: counters-only bound (3*147=441) should reject a 30000/min rate even with the fallback on: %+v", m)
		}
	}
	if got := dec.EnrichedMsg["counters_only_mode"]; got != true {
		t.Errorf("counters_only_mode should win: got %v", got)
	}
	if _, ok := dec.EnrichedMsg["no_speed_guard_fallback"]; ok {
		t.Errorf("no_speed_guard_fallback set despite counters-only taking precedence")
	}
}
