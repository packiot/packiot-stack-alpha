package deriver_test

// This test reproduces cmd/sparkplug-agent's `ingest` closure logic around the
// derive stage (ADR-0045 P2c) against a minimal resolver + tagstore, proving the
// wiring contract: the deriver's synthesized counts are INJECTED (resolve+store)
// and a sum's ADDEND suffixes are CONSUMED — dropped from the passthrough, never
// stored/published (republishing a partial/duplicate addend looks like a
// totalizer drop to Calc).

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/deriver"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// mapResolver is the minimal session.Resolver: a suffix→ok allowlist, matching
// what newResolver builds from the raw_tag_map metric_suffix set.
type mapResolver struct{ allow map[string]bool }

func (r mapResolver) Resolve(suffix string) (string, sparkplug.DataType, bool) {
	if r.allow[suffix] {
		return "PREFIX" + suffix, sparkplug.DataType_Double, true
	}
	return "", 0, false
}

// runIngest is the ingest closure's derive+resolve+store body, verbatim in shape.
func runIngest(d *deriver.Deriver, resolver mapResolver, store *tagstore.Store, tags []rawtag.RawTag) {
	var synth []rawtag.RawTag
	var consumed map[string]bool
	if d != nil {
		synth, consumed = d.Process(tags)
	}
	for _, t := range tags {
		if consumed[t.Metric] {
			continue // sum addend folded in — drop, do not publish
		}
		if _, _, ok := resolver.Resolve(t.Metric); !ok {
			continue
		}
		store.Apply(t)
	}
	for _, t := range synth {
		if _, _, ok := resolver.Resolve(t.Metric); !ok {
			continue
		}
		store.Apply(t)
	}
}

func TestWiring_SumAddendsConsumed_SynthPublished(t *testing.T) {
	addA := "/L5/PTH/Status/CountA"
	addB := "/L5/PTH/Status/CountB"
	emit := "/L5/PTH/Admin/ProdConsumedCount/70/Unit"

	prof := &tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/L5/PTH",
			Emit:    []string{emit},
			Type:    "double",
			Sum:     &tenantprofile.SumSource{Addends: []string{addA, addB}},
		}},
	}
	d := deriver.New(prof)

	// The allowlist: the derived EMIT suffix is present (SynthesizeEquipment would
	// have added it); the raw addends are NOT (they are consumed, not republished).
	resolver := mapResolver{allow: map[string]bool{emit: true}}
	store := tagstore.New()

	runIngest(d, resolver, store, []rawtag.RawTag{
		{Metric: addA, Value: 100.0, TsMillis: 1000, Quality: true},
		{Metric: addB, Value: 200.0, TsMillis: 1000, Quality: true},
	})

	// Exactly one stored tag: the synthesized sum. The two addends were consumed.
	if store.Len() != 1 {
		t.Fatalf("tagstore Len: got %d, want 1 (only the synthesized count)", store.Len())
	}
	dirty := store.DrainDirty()
	if len(dirty) != 1 || dirty[0].Metric != emit {
		t.Fatalf("published tag: got %+v, want single %q", dirty, emit)
	}
	if v, _ := dirty[0].Value.(float64); v != 300 {
		t.Fatalf("synthesized sum value: got %v, want 300", dirty[0].Value)
	}
}

func TestWiring_IntegralSynthPublished_SourcePassesThrough(t *testing.T) {
	src := "/L5/FLEXO/Status/CurMachSpeed"
	emit := "/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"

	prof := &tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment:  "/L5/FLEXO",
			Emit:     []string{emit},
			Type:     "double",
			Integral: &tenantprofile.IntegralSource{Source: src, Conversion: 1.0},
		}},
	}
	d := deriver.New(prof)
	// The emit suffix is allowlisted; the raw speed source is NOT (a FLEXO whose
	// speed is not a canonical metric simply drops as unmapped — it is NOT
	// consumed, so the drop is the normal allowlist path, not a derive drop).
	resolver := mapResolver{allow: map[string]bool{emit: true}}
	store := tagstore.New()

	// Seed tick emits (and thus publishes) an EXPLICIT absolute 0 baseline — the
	// ADR-0045 P1 handshake so the cloud Calc seeds its first-observation baseline
	// to 0 and the first real window is not dropped as a spike. So the seed now
	// stores exactly the one 0-valued synthesized count.
	runIngest(d, resolver, store, []rawtag.RawTag{{Metric: src, Value: 10.0, TsMillis: 0, Quality: true}}) // seed
	if store.Len() != 1 {
		t.Fatalf("seed sample must store the absolute-0 baseline, got Len %d", store.Len())
	}
	if dirty := store.DrainDirty(); len(dirty) != 1 || dirty[0].Metric != emit {
		t.Fatalf("seed published tag: got %+v, want single %q", dirty, emit)
	} else if v, _ := dirty[0].Value.(float64); v != 0 {
		t.Fatalf("seed baseline value: got %v, want 0", dirty[0].Value)
	}
	runIngest(d, resolver, store, []rawtag.RawTag{{Metric: src, Value: 10.0, TsMillis: 1000, Quality: true}})
	if store.Len() != 1 {
		t.Fatalf("tagstore Len: got %d, want 1 (the synthesized integral count)", store.Len())
	}
}
