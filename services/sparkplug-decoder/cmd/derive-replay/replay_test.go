package main

import (
	"path/filepath"
	"runtime"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// exampleDescriptor locates the shipped derived-metrics example relative to this
// test file, so the harness is proven against the exact artifact under
// docs/clients/examples/ (cmd/derive-replay → repo root is four parents up).
func exampleDescriptor(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	pkgDir := filepath.Dir(thisFile)
	return filepath.Join(pkgDir, "..", "..", "..", "..",
		"docs", "clients", "examples", "derived.descriptor.yaml")
}

func find(emitted []Emitted, metric string) (any, bool) {
	var v any
	found := false
	for _, e := range emitted {
		if e.Metric == metric {
			v = e.Value
			found = true
		}
	}
	return v, found
}

// TestReplay_ScrapExpr_EndToEnd is the ADR-0058 integration hardproof: the SAME
// production path a real client uses (Load → GenerateProfile → deriver) turns two
// captured raw registers into a derived scrap count. It proves the whole chain,
// not a hand-built Profile — a mis-resolved rule (wrong {idx}/segment/var) would
// surface here as a missing or wrong tag.
func TestReplay_ScrapExpr_EndToEnd(t *testing.T) {
	d, err := clientdescriptor.Load(exampleDescriptor(t))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	profile, err := d.GenerateProfile()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	// The SCRAP equipment authors expr scrap = gross - net over /Status/DW0 and
	// /Status/DW4 (segment-qualified to /L5/SCRAP at generate). Feed representative
	// captured values in separate envelopes to also exercise cross-envelope latch.
	samples := []rawtag.RawTag{
		{Metric: "/L5/SCRAP/Status/DW0", Value: 100.0, TsMillis: 1000, Quality: true},
		{Metric: "/L5/SCRAP/Status/DW4", Value: 88.0, TsMillis: 1000, Quality: true},
	}
	emitted := Replay(profile, samples)

	const scrap = "/L5/SCRAP/Admin/ProdDefectiveCount/73/Unit"
	v, ok := find(emitted, scrap)
	if !ok {
		t.Fatalf("no scrap tag emitted; got %+v", emitted)
	}
	if v != 12.0 {
		t.Fatalf("scrap = gross-net: got %v, want 12", v)
	}
}

// TestReplay_NoEmitUntilBothInputs proves the latch: the first envelope (only
// gross) must not emit — a partial expr is garbage until every var is seen.
func TestReplay_NoEmitUntilBothInputs(t *testing.T) {
	d, err := clientdescriptor.Load(exampleDescriptor(t))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	profile, err := d.GenerateProfile()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	only := []rawtag.RawTag{{Metric: "/L5/SCRAP/Status/DW0", Value: 100.0, TsMillis: 1000, Quality: true}}
	if emitted := Replay(profile, only); len(emitted) != 0 {
		t.Fatalf("expr must not emit before both vars seen, got %+v", emitted)
	}
}
