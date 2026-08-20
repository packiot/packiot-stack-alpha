// Tests for the ADR-0047 P0 #1 counter-role override (Message.RoleKind /
// Message.RoleUnitTopic) — the packml_register.id_{infeed,outfeed,reject}counter
// wiring. See calc.go's Message.RoleKind doc for the full design rationale.

package calc_production_counters

import (
	"strings"
	"testing"
	"time"
)

// ── Shared-helper parity: DeriveUnitTopic / parseTriggerFlags must exactly
// match parseTopicFull's own inline derivation, or a resolver's keys silently
// go dead (the "key drift" lesson from ADR-0045 G4/G5's countersrate seam).

func TestDeriveUnitTopicMatchesParseTopicFull(t *testing.T) {
	cases := []string{
		"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit***TRIG",
		"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CS",
		"CPACK/SC/CELULA1/CER400/CER400/Status/ProdProcessedCount/12/Unit***TRIG",
		"CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/51/Unit***TRIG", // line own-stream
	}
	for _, in := range cases {
		wantUnit, _, err := ParseTopic(in)
		if err != nil {
			t.Fatalf("ParseTopic(%q) errored: %v", in, err)
		}
		gotUnit, ok := DeriveUnitTopic(in)
		if !ok {
			t.Fatalf("DeriveUnitTopic(%q): ok=false, want true", in)
		}
		if gotUnit != wantUnit {
			t.Errorf("DeriveUnitTopic(%q) = %q, want %q (parseTopicFull)", in, gotUnit, wantUnit)
		}
	}
}

// DeriveUnitTopic must ALSO work on a bare, non-standard-named metric with NO
// "***" suffix and no Prod*Count substring — this is precisely the case
// parseTopicFull rejects (ErrMalformedTopic) and the whole reason the
// counter-role resolver exists.
func TestDeriveUnitTopicToleratesNonStandardName(t *testing.T) {
	in := "BISPHARMA/SP/LINHAS/L01/S1_INFEED/Admin/counter168/61/Unit"
	got, ok := DeriveUnitTopic(in)
	if !ok {
		t.Fatalf("DeriveUnitTopic(%q): ok=false, want true", in)
	}
	want := "BISPHARMA/SP/LINHAS/L01/S1_INFEED"
	if got != want {
		t.Errorf("DeriveUnitTopic(%q) = %q, want %q", in, got, want)
	}
	// parseTopicFull must reject the same input (proves the gap this closes).
	if _, _, err := ParseTopic(in); err == nil {
		t.Errorf("ParseTopic(%q) unexpectedly succeeded — expected ErrMalformedTopic (the split-brain this resolver routes around)", in)
	}
}

func TestParseTriggerFlagsMatchesParseTopicFull(t *testing.T) {
	cases := []struct {
		topic string
		want  TriggerFlags
	}{
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CS", TriggerFlags{TrigBase: true, TrigCS: true}},
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CO", TriggerFlags{TrigBase: true, TrigCO: true}},
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit***STATESPEED_THIS", TriggerFlags{StateSpeedThis: true}},
	}
	for _, tc := range cases {
		_, _, wantFlags, err := parseTopicFull(tc.topic)
		if err != nil {
			t.Fatalf("parseTopicFull(%q) errored: %v", tc.topic, err)
		}
		if wantFlags != tc.want {
			t.Fatalf("test setup: parseTopicFull(%q) flags = %+v, want %+v", tc.topic, wantFlags, tc.want)
		}
		sepIdx := strings.Index(tc.topic, "***")
		if sepIdx < 0 {
			t.Fatalf("test setup: %q has no *** separator", tc.topic)
		}
		suffix := tc.topic[sepIdx+3:]
		got := parseTriggerFlags(suffix)
		if got != tc.want {
			t.Errorf("parseTriggerFlags(%q) = %+v, want %+v", suffix, got, tc.want)
		}
	}
}

// ── Calc() with a role override ───────────────────────────────────────────

// TestCalcRoleOverrideNonStandardTopicName is the headline case: a topic that
// would be ErrMalformedTopic under the substring path (no Prod*Count
// substring — bispharma's "counter168" convention) becomes a fully-processed
// Consumed(gross) counter for the LINE once RoleKind/RoleUnitTopic are set,
// and its emitted metric + state land under the LINE's own canonical
// Admin/ProdConsumedCount key, not the source topic.
func TestCalcRoleOverrideNonStandardTopicName(t *testing.T) {
	s := NewMemState()
	lineUnit := "BISPHARMA/SP/LINHAS/L01"
	s.SetInt(lineUnit+"/Admin/ProdConsumedCount", 100)
	s.SetFloat(lineUnit+"/Status/MachSpeed", 1000.0) // clears the glitch guard

	msg := Message{
		Topic:         "BISPHARMA/SP/LINHAS/L01/S1_INFEED/Admin/counter168/61/Unit",
		Payload:       110, // +10 increment
		CmdTrigger:    true,
		Timestamp:     time.UnixMilli(1700000000000),
		RoleUnitTopic: lineUnit,
		RoleKind:      CounterKindConsumed,
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true")
	}
	var consumed *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == lineUnit+"/Admin/ProdConsumedCount" {
			consumed = &dec.Metrics[i]
		}
	}
	if consumed == nil {
		t.Fatalf("no line-scoped Consumed metric emitted, got: %+v", dec.Metrics)
	}
	if consumed.Value != 10 {
		t.Errorf("Consumed.Value: got %d, want 10", consumed.Value)
	}
	if consumed.Counter != 110 {
		t.Errorf("Consumed.Counter: got %d, want 110", consumed.Counter)
	}
	if !hasCounterUpdate(dec.StateUpdates, lineUnit+"/Admin/ProdConsumedCount", 110) {
		t.Errorf("state updates missing line Consumed=110: %+v", dec.StateUpdates)
	}
	// Must NOT have written state under the raw source topic — that would be
	// a state leak the next sample could never read back correctly.
	if _, ok := s.Int("BISPHARMA/SP/LINHAS/L01/S1_INFEED/Admin/counter168/61/Unit"); ok {
		t.Errorf("state written under the raw source topic — should only touch the line-scoped key")
	}
}

// TestCalcRoleOverrideZeroValueIsExactlyTheSubstringPath proves the
// backward-compat contract: a Message with RoleKind left at its zero value
// (CounterKindUnknown) produces a BYTE-IDENTICAL Decision to a plain message
// — the override is inert unless a caller explicitly resolved a DB role.
func TestCalcRoleOverrideZeroValueIsExactlyTheSubstringPath(t *testing.T) {
	s1 := NewMemState()
	s2 := NewMemState()
	base := "CPACK/SC/LINHAS/L5/BREYER"
	for _, s := range []State{s1, s2} {
		s.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 90)
		s.SetFloat(base+"/Status/MachSpeed", 100.0)
	}

	plain := Message{
		Topic:      base + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    95,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	withZeroOverride := plain
	withZeroOverride.RoleUnitTopic = ""            // zero value
	withZeroOverride.RoleKind = CounterKindUnknown // zero value

	dec1, err1 := Calc(plain, s1)
	dec2, err2 := Calc(withZeroOverride, s2)
	if err1 != nil || err2 != nil {
		t.Fatalf("Calc errors: %v / %v", err1, err2)
	}
	if dec1.SendDownstream != dec2.SendDownstream {
		t.Fatalf("SendDownstream diverged: %v vs %v", dec1.SendDownstream, dec2.SendDownstream)
	}
	if len(dec1.Metrics) != len(dec2.Metrics) {
		t.Fatalf("Metrics count diverged: %d vs %d", len(dec1.Metrics), len(dec2.Metrics))
	}
	for i := range dec1.Metrics {
		if dec1.Metrics[i].Name != dec2.Metrics[i].Name || dec1.Metrics[i].Value != dec2.Metrics[i].Value {
			t.Errorf("Metric[%d] diverged: %+v vs %+v", i, dec1.Metrics[i], dec2.Metrics[i])
		}
	}
}

// TestCalcRoleOverrideSkipsPhase9 proves Phase 9 (member→line CSV
// aggregation) never runs for an override message — it must not panic on a
// short/non-standard topic shape, and must not emit any LineAggregated
// metric (DB-role mapping and CSV-position mapping are alternatives, not
// layered).
func TestCalcRoleOverrideSkipsPhase9(t *testing.T) {
	s := NewMemState()
	lineUnit := "BISPHARMA/SP/LINHAS/L01"
	s.SetFloat(lineUnit+"/Status/MachSpeed", 1000.0)
	// Deliberately short/atypical topic (would panic Phase 9's topicArray[7]
	// index if it ran unguarded).
	msg := Message{
		Topic:         "short/topic",
		Payload:       10,
		CmdTrigger:    true,
		Timestamp:     time.UnixMilli(1700000000000),
		RoleUnitTopic: lineUnit,
		RoleKind:      CounterKindConsumed,
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	for _, m := range dec.Metrics {
		if m.LineAggregated {
			t.Errorf("unexpected Phase-9 LineAggregated metric for a role-override message: %+v", m)
		}
	}
}
