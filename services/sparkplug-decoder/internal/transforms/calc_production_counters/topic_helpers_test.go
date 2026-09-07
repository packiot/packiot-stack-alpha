// Parity tests for the shared topic-derivation helpers (DeriveUnitTopic /
// parseTriggerFlags) — they must exactly match parseTopicFull's own inline
// derivation, or any caller that builds a canonical unit-topic lookup key
// silently goes dead (the "key drift" lesson from ADR-0045 G4/G5's countersrate
// seam).

package calc_production_counters

import (
	"strings"
	"testing"
)

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
// parseTopicFull rejects (ErrMalformedTopic).
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
		t.Errorf("ParseTopic(%q) unexpectedly succeeded — expected ErrMalformedTopic", in)
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
