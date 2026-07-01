// Scaffold tests. Currently proves:
//   - The public API compiles + shapes are correct
//   - ParseTopic + kindFromSuffix round-trip correctly on the canonical
//     Sparkplug counter topics
//   - The in-memory State reference implementation satisfies the interface
//
// The comparator + fixture-corpus tests land alongside the actual port
// in a follow-up PR — see docs/phase-3-calc-production-counters-port-plan.md
// § 5 for the validation methodology.

package calc_production_counters

import (
	"errors"
	"testing"
)

func TestCalcReturnsNotImplementedInScaffold(t *testing.T) {
	// Guardrail: the port PR will delete this test when Calc actually
	// works. Until then, the scaffold MUST return ErrNotImplemented so
	// callers know to fall back to the Node-RED path.
	msg := Message{
		Topic:   "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***IN",
		Payload: 12345,
		Tenant:  "cpack",
	}
	_, err := Calc(msg, NewMemState())
	if !errors.Is(err, ErrNotImplemented) {
		t.Errorf("scaffold should return ErrNotImplemented, got %v", err)
	}
}

// ── ParseTopic ──────────────────────────────────────────────────────────────

func TestParseTopicCanonicalShapes(t *testing.T) {
	cases := []struct {
		name         string
		in           string
		wantUnit     string
		wantKind     CounterKind
	}{
		{
			name:     "consumed IN",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***IN",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindConsumed,
		},
		{
			name:     "processed OUT",
			in:       "CPACK/SC/LINHAS/L5/POLYTYPE/Admin/ProdProcessedCount/62/Unit***OUT",
			wantUnit: "CPACK/SC/LINHAS/L5/POLYTYPE",
			wantKind: CounterKindProcessed,
		},
		{
			name:     "scrapped SCRAPED",
			in:       "CPACK/SC/LINHAS/L5/PTH/Admin/ProdScrappedCount/63/Unit***SCRAPED",
			wantUnit: "CPACK/SC/LINHAS/L5/PTH",
			wantKind: CounterKindScrapped,
		},
		{
			name:     "trigger TRIG",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/Trigger/61/Unit***TRIG",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindTrigger,
		},
		{
			name:     "case-insensitive suffix",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/X/61/Unit***in",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindConsumed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			unit, kind, err := ParseTopic(tc.in)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if unit != tc.wantUnit {
				t.Errorf("unitTopic: got %q, want %q", unit, tc.wantUnit)
			}
			if kind != tc.wantKind {
				t.Errorf("kind: got %v, want %v", kind, tc.wantKind)
			}
		})
	}
}

func TestParseTopicRejectsBadInputs(t *testing.T) {
	bad := []string{
		"",                                                     // empty
		"CPACK/SC/LINHAS/L5/BREYER/Admin/Count",                // no *** suffix
		"CPACK/SC/LINHAS/L5/BREYER/Admin/Count/61/Unit***JUNK", // unknown suffix
		"too/few/parts***IN",                                   // <5 unit segments
	}
	for _, in := range bad {
		t.Run(in, func(t *testing.T) {
			_, _, err := ParseTopic(in)
			if !errors.Is(err, ErrMalformedTopic) {
				t.Errorf("input %q: want ErrMalformedTopic, got %v", in, err)
			}
		})
	}
}

// ── In-memory State reference ───────────────────────────────────────────────

func TestMemStateSatisfiesInterface(t *testing.T) {
	var _ State = NewMemState()
	// Compile-time assertion is the whole test — if State's interface
	// changes and memState doesn't keep up, this fails to build.
}

func TestMemStateModesRoundTrip(t *testing.T) {
	s := NewMemState().(*memState)
	// Default: unknown, not-set
	m, ok := s.Modes("CPACK/SC/LINHAS/L5/BREYER")
	if m != UnitModeUnknown || ok {
		t.Errorf("empty state: got mode=%v ok=%v, want (Unknown, false)", m, ok)
	}
	// After SetMode: set
	s.SetMode("CPACK/SC/LINHAS/L5/BREYER", UnitModeExecute)
	m, ok = s.Modes("CPACK/SC/LINHAS/L5/BREYER")
	if m != UnitModeExecute || !ok {
		t.Errorf("after SetMode: got mode=%v ok=%v, want (Execute, true)", m, ok)
	}
}

func TestMemStateCounterCumulativeRoundTrip(t *testing.T) {
	s := NewMemState()
	// Default: zero, nil error
	v, err := s.CounterCumulative("CPACK/SC/LINHAS/L5/BREYER", CounterKindConsumed)
	if err != nil || v != 0 {
		t.Errorf("empty counter: got v=%d err=%v, want (0, nil)", v, err)
	}
	// After SetCounterCumulative: reads back
	if err := s.SetCounterCumulative("CPACK/SC/LINHAS/L5/BREYER", CounterKindConsumed, 12345); err != nil {
		t.Fatalf("set: %v", err)
	}
	v, err = s.CounterCumulative("CPACK/SC/LINHAS/L5/BREYER", CounterKindConsumed)
	if err != nil || v != 12345 {
		t.Errorf("after set: got v=%d err=%v, want (12345, nil)", v, err)
	}
}

func TestMemStateConfigNotFoundReturnsErrNotConfigured(t *testing.T) {
	s := NewMemState()
	_, err := s.PackMLConfig("CPACK/SC/UNKNOWN/X/Y")
	if !errors.Is(err, ErrNotConfigured) {
		t.Errorf("unknown unit: want ErrNotConfigured, got %v", err)
	}
}
