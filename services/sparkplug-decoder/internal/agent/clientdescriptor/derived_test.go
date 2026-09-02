package clientdescriptor

import (
	"path/filepath"
	"runtime"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// derivedDescriptorPath locates the shipped derived-metrics example relative to
// THIS test file, so the test proves the exact artifact under docs/clients/
// examples/ rather than an inline copy that could drift.
func derivedDescriptorPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	pkgDir := filepath.Dir(thisFile)
	return filepath.Join(pkgDir, "..", "..", "..", "..", "..",
		"docs", "clients", "examples", "derived.descriptor.yaml")
}

// TestDerivedExample_GeneratesAndValidates runs the shipped FLEXO+PTH example
// through the SAME path onboard-gen uses (Load → Generate) and asserts the
// derived Emit leaves land in BOTH the profile's derived rules and the agent
// raw_tag_map allowlist — while the sum ADDENDS do NOT (they are consumed).
func TestDerivedExample_GeneratesAndValidates(t *testing.T) {
	d, err := Load(derivedDescriptorPath(t)) // Load runs full Validate (incl. generated profile)
	if err != nil {
		t.Fatalf("load derived example: %v", err)
	}

	art, err := d.Generate(GenerateOptions{Cutover: true}) // both indices confirmed → cutover-eligible
	if err != nil {
		t.Fatalf("Generate(cutover): %v", err)
	}

	// The agent raw_tag_map MUST contain the derived count leaves at the resolved
	// count indices (FLEXO idx 61: both Consumed+Processed; PTH idx 70: Consumed).
	suffixes := map[string]bool{}
	for _, e := range art.AgentConfig.RawTagMap {
		suffixes[e.MetricSuffix] = true
	}
	wantPresent := []string{
		"/L5/FLEXO/Admin/ProdConsumedCount/61/Unit",
		"/L5/FLEXO/Admin/ProdProcessedCount/61/Unit",
		"/L5/PTH/Admin/ProdConsumedCount/70/Unit",
	}
	for _, w := range wantPresent {
		if !suffixes[w] {
			t.Errorf("agent raw_tag_map missing derived leaf %q; have %v", w, keysOf(suffixes))
		}
	}
	// The sum ADDENDS must NOT be allowlisted (they are consumed, not republished).
	for _, bad := range []string{"/L5/PTH/Status/CountA", "/L5/PTH/Status/CountB"} {
		if suffixes[bad] {
			t.Errorf("agent raw_tag_map must NOT allowlist consumed sum addend %q", bad)
		}
	}

	// The generated profile carries the resolved derived rules the runtime deriver
	// consumes — one integral (FLEXO, 2 emit leaves) + one sum (PTH, 2 addends).
	var nIntegral, nSum int
	for _, r := range art.Profile.Derived {
		if r.Integral != nil {
			nIntegral++
			if r.Integral.Source != "/L5/FLEXO/Status/CurMachSpeed" {
				t.Errorf("integral source not segment-qualified: %q", r.Integral.Source)
			}
			if len(r.Emit) != 2 {
				t.Errorf("FLEXO integral should emit 2 leaves, got %d", len(r.Emit))
			}
		}
		if r.Sum != nil {
			nSum++
			if len(r.Sum.Addends) != 2 || r.Sum.Addends[0] != "/L5/PTH/Status/CountA" {
				t.Errorf("PTH sum addends not segment-qualified: %v", r.Sum.Addends)
			}
		}
	}
	if nIntegral != 1 || nSum != 1 {
		t.Fatalf("profile derived rules: got %d integral + %d sum, want 1 + 1", nIntegral, nSum)
	}

	// UnmappedTopics must stay empty — every equipment synthesizes ≥1 metric.
	unmapped, err := d.UnmappedTopics()
	if err != nil {
		t.Fatalf("UnmappedTopics: %v", err)
	}
	if len(unmapped) != 0 {
		t.Errorf("UnmappedTopics should be empty, got %v", unmapped)
	}
}

// TestDerived_SynthesizeEquipment_AddsEmitLeaves is the focused §C pin: the
// derived Emit leaves are appended by SynthesizeEquipment (the single synth path
// both GenerateAgentConfig and the register loader use), and a leaf a template
// ALSO produces is not duplicated.
func TestDerived_SynthesizeEquipment_AddsEmitLeaves(t *testing.T) {
	p := &tenantprofile.Profile{
		TenantPrefix: "T/SP",
		MetricTemplates: tenantprofile.MetricTemplates{
			Member: []tenantprofile.TemplateEntry{{Leaf: "/Status/MachSpeed", Type: "double"}},
		},
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/L5/FLEXO",
			Emit:    []string{"/L5/FLEXO/Admin/ProdConsumedCount/61/Unit", "/L5/FLEXO/Status/MachSpeed"},
			Type:    "double",
			Integral: &tenantprofile.IntegralSource{
				Source: "/L5/FLEXO/Status/CurMachSpeed", Conversion: 1,
			},
		}},
	}
	if err := p.Validate(); err != nil {
		t.Fatalf("profile validate: %v", err)
	}
	metrics, err := p.SynthesizeEquipment("/L5/FLEXO", tenantprofile.ClassMember, 5001)
	if err != nil {
		t.Fatalf("SynthesizeEquipment: %v", err)
	}
	got := map[string]int{}
	for _, m := range metrics {
		got[m.Suffix]++
	}
	if got["/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"] != 1 {
		t.Errorf("derived Consumed leaf not synthesized exactly once: %v", got)
	}
	// The MachSpeed leaf is produced by the template AND listed in derived Emit —
	// it must appear exactly ONCE (dedup), not twice.
	if got["/L5/FLEXO/Status/MachSpeed"] != 1 {
		t.Errorf("MachSpeed must dedup to one entry, got %d", got["/L5/FLEXO/Status/MachSpeed"])
	}
}

func keysOf(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
