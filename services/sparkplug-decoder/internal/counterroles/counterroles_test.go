package counterroles

import (
	"testing"

	calc "github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/transforms/calc_production_counters"
)

// TestBuildBindingsBasic proves the CPACK split-instrumentation shape: a
// LINE's gross counter lives on one machine, net on another, each declared
// via a distinct role row — both should resolve, keyed by the SOURCE
// machine's own canonical unit topic.
func TestBuildBindingsBasic(t *testing.T) {
	rows := []roleRow{
		{LineTopic: "CPACK/SC/LINHAS/L3", SourceTopic: "CPACK/SC/LINHAS/L3/POLYTYPE", Role: 1}, // infeed/gross
		{LineTopic: "CPACK/SC/LINHAS/L3", SourceTopic: "CPACK/SC/LINHAS/L3/BREYER", Role: 2},   // outfeed/net
	}
	got := buildBindings(rows)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2: %+v", len(got), got)
	}
	if b, ok := got["CPACK/SC/LINHAS/L3/POLYTYPE"]; !ok || b.Role != calc.CounterKindConsumed || b.LineUnitTopic != "CPACK/SC/LINHAS/L3" {
		t.Errorf("infeed binding wrong: %+v ok=%v", b, ok)
	}
	if b, ok := got["CPACK/SC/LINHAS/L3/BREYER"]; !ok || b.Role != calc.CounterKindProcessed || b.LineUnitTopic != "CPACK/SC/LINHAS/L3" {
		t.Errorf("outfeed binding wrong: %+v ok=%v", b, ok)
	}
}

// TestBuildBindingsRejectCounter proves the third role (scrap) resolves too,
// and that per-metric (long, per-tag) topic shapes on either side still
// canonicalize to the same key a live metric's own DeriveUnitTopic call
// would produce.
func TestBuildBindingsRejectCounter(t *testing.T) {
	rows := []roleRow{
		{
			LineTopic:   "BISPHARMA/SP/LINHAS/L01",
			SourceTopic: "BISPHARMA/SP/LINHAS/L01/SCRAP/Admin/counter169/61/Unit", // per-metric shape
			Role:        3,
		},
	}
	got := buildBindings(rows)
	want := "BISPHARMA/SP/LINHAS/L01/SCRAP"
	b, ok := got[want]
	if !ok {
		t.Fatalf("missing binding for %q, got: %+v", want, got)
	}
	if b.Role != calc.CounterKindDefective || b.LineUnitTopic != "BISPHARMA/SP/LINHAS/L01" {
		t.Errorf("reject binding wrong: %+v", b)
	}
}

// TestBuildBindingsShortCanonicalLineTopic proves a LINE's own canonical
// topic — very often shorter than 5 segments in packml_register (e.g. a
// bare "CPACK/SC/LINHAS/L3" with no per-metric leaf) — resolves as itself
// rather than being dropped as malformed. This is the real DB shape: a
// tp_equipment=3 LINE's shortest active packml_topic row commonly has no
// Prod*Count leaf at all.
func TestBuildBindingsShortCanonicalLineTopic(t *testing.T) {
	rows := []roleRow{
		{LineTopic: "CPACK/SC/LINHAS/L3", SourceTopic: "CPACK/SC/LINHAS/L3/POLYTYPE", Role: 1},
	}
	got := buildBindings(rows)
	b, ok := got["CPACK/SC/LINHAS/L3/POLYTYPE"]
	if !ok {
		t.Fatalf("missing binding, got: %+v", got)
	}
	if b.LineUnitTopic != "CPACK/SC/LINHAS/L3" {
		t.Errorf("LineUnitTopic: got %q, want unchanged %q", b.LineUnitTopic, "CPACK/SC/LINHAS/L3")
	}
}

// TestBuildBindingsSkipsEmptyTopics proves a genuinely empty topic string
// (defensive — a NULL/blank packml_topic should never reach here given the
// query's own "packml_topic IS NOT NULL" filter, but a resolver must not
// trust that at the Go layer) is dropped rather than producing a bad
// empty-string key.
func TestBuildBindingsSkipsEmptyTopics(t *testing.T) {
	rows := []roleRow{
		{LineTopic: "", SourceTopic: "CPACK/SC/LINHAS/L3/POLYTYPE", Role: 1},
		{LineTopic: "CPACK/SC/LINHAS/L3", SourceTopic: "", Role: 2},
	}
	got := buildBindings(rows)
	if len(got) != 0 {
		t.Errorf("expected 0 bindings from empty topics, got: %+v", got)
	}
}

// TestBuildBindingsUnknownRoleSkipped proves an out-of-range role int
// (defensive — SQL only ever emits 1/2/3) never produces a phantom binding.
func TestBuildBindingsUnknownRoleSkipped(t *testing.T) {
	rows := []roleRow{
		{LineTopic: "CPACK/SC/LINHAS/L3", SourceTopic: "CPACK/SC/LINHAS/L3/POLYTYPE", Role: 99},
	}
	got := buildBindings(rows)
	if len(got) != 0 {
		t.Errorf("expected 0 bindings for unknown role, got: %+v", got)
	}
}

// TestBuildBindingsEmpty proves the everyone-today shape (no packml_register
// row has any of the three role columns set) yields an empty map, not nil
// panics or a bogus entry — the ADR-0047 backward-compat no-op case.
func TestBuildBindingsEmpty(t *testing.T) {
	got := buildBindings(nil)
	if len(got) != 0 {
		t.Errorf("expected empty map, got: %+v", got)
	}
}

// TestResolverResolveMissDefaultsSafely proves a Resolver with an empty
// snapshot (e.g. DB unreachable on first load, or simply no tenant has
// populated the columns) fails closed — every Resolve() call is a miss, not
// a panic or a guessed binding.
func TestResolverResolveMissDefaultsSafely(t *testing.T) {
	r := New(nil, 0) // zero TTL ⇒ DefaultTTL; nil logger ⇒ slog.Default()
	kind, unit, ok := r.Resolve("CPACK/SC/LINHAS/L3/POLYTYPE")
	if ok || kind != calc.CounterKindUnknown || unit != "" {
		t.Errorf("Resolve on empty resolver: got (%v,%q,%v), want (Unknown,\"\",false)", kind, unit, ok)
	}
	if r.Len() != 0 {
		t.Errorf("Len() = %d, want 0", r.Len())
	}
}
