package counterderive

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// TestApply is the closed-enum arithmetic gate: every counter_derive mode is
// exercised with the exact numbers the CPACK Calc_Counters decode specifies, so
// a regression in any leg fails here. Slots are seeded with sentinels for the
// UNSENSED roles (per the mode) to prove Apply overwrites them; sensed roles hold
// the "read" value.
func TestApply(t *testing.T) {
	const sentinel = -999 // an obviously-wrong value a derived slot must overwrite
	cases := []struct {
		name                string
		mode                string
		inG, inN, inS       float64
		wantG, wantN, wantS float64
	}{
		// full / none: pass-through, every slot untouched.
		{"full", ModeFull, 100, 90, 10, 100, 90, 10},
		{"empty_is_full", "", 100, 90, 10, 100, 90, 10},
		{"none", ModeNone, 100, 90, 10, 100, 90, 10},

		// outfeed_only: gross sensed → net:=gross, scrap:=0.
		{"outfeed_only", ModeOutfeedOnly, 250, sentinel, sentinel, 250, 250, 0},

		// infeed_only: net sensed → gross:=net, scrap:=0.
		{"infeed_only", ModeInfeedOnly, sentinel, 175, sentinel, 175, 175, 0},

		// scrap_derived: gross+net → scrap:=gross-net.
		{"scrap_derived", ModeScrapDerived, 300, 280, sentinel, 300, 280, 20},
		// scrap_derived floors at 0 when net>gross (out-of-order totalizers).
		{"scrap_derived_floor", ModeScrapDerived, 100, 130, sentinel, 100, 130, 0},

		// gross_derived: net+scrap → gross:=net+scrap.
		{"gross_derived", ModeGrossDerived, sentinel, 200, 15, 215, 200, 15},

		// outfeed_derived (APPROXIMATION): gross+scrap → net:=max(gross-scrap,0).
		{"outfeed_derived", ModeOutfeedDerived, 400, sentinel, 25, 400, 375, 25},
		{"outfeed_derived_floor", ModeOutfeedDerived, 10, sentinel, 40, 10, 0, 40},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			g, n, s := tc.inG, tc.inN, tc.inS
			if err := Apply(&g, &n, &s, tc.mode); err != nil {
				t.Fatalf("Apply(%s): unexpected error: %v", tc.mode, err)
			}
			if g != tc.wantG || n != tc.wantN || s != tc.wantS {
				t.Errorf("Apply(%s): got g=%v n=%v s=%v, want g=%v n=%v s=%v",
					tc.mode, g, n, s, tc.wantG, tc.wantN, tc.wantS)
			}
		})
	}
}

// TestApply_UnknownMode proves an out-of-enum mode is an error, not a silent
// no-op (the loader lint prevents it upstream; this is the belt-and-braces leg).
func TestApply_UnknownMode(t *testing.T) {
	g, n, s := 1.0, 2.0, 3.0
	if err := Apply(&g, &n, &s, "bogus_mode"); err == nil {
		t.Fatal("Apply with an unknown mode must return an error")
	}
}

// countTag is a tiny helper to build a canonical count rawtag for a group.
func countTag(suffix string, v float64, ts int64) rawtag.RawTag {
	return rawtag.RawTag{Metric: suffix, Value: v, TsMillis: ts, Quality: true}
}

// TestStage_SynthesizesMissingCounts drives the runtime wiring end to end: a
// member declared infeed_only (only net sensed) must synthesize gross:=net and
// scrap:=0 at the leaf-swapped sibling suffixes, and a scrap_derived member must
// synthesize scrap:=gross-net — proving group correlation by (head, idx).
func TestStage_SynthesizesMissingCounts(t *testing.T) {
	const (
		netA   = "/L5/M1/Admin/ProdProcessedCount/5/Unit" // net leaf, group A (idx 5)
		grossA = "/L5/M1/Admin/ProdConsumedCount/5/Unit"
		scrapA = "/L5/M1/Admin/ProdDefectiveCount/5/Unit"

		grossB = "/L5/M2/Admin/ProdConsumedCount/7/Unit" // group B (idx 7), scrap_derived
		netB   = "/L5/M2/Admin/ProdProcessedCount/7/Unit"
		scrapB = "/L5/M2/Admin/ProdDefectiveCount/7/Unit"
	)
	st := New([]Entry{
		{Suffix: netA, Mode: ModeInfeedOnly},
		{Suffix: grossB, Mode: ModeScrapDerived},
		{Suffix: netB, Mode: ModeScrapDerived},
		// A full/none/speed entry must not build a group.
		{Suffix: "/L5/M3/Admin/ProdConsumedCount/9/Unit", Mode: ModeFull},
		{Suffix: "/L5/M1/Status/MachSpeed", Mode: ModeInfeedOnly},
	})
	if st.Empty() {
		t.Fatal("stage should have compiled two derive groups")
	}

	synth := st.Process([]rawtag.RawTag{
		countTag(netA, 175, 1000),   // group A: net sensed
		countTag(grossB, 300, 2000), // group B: gross+net sensed
		countTag(netB, 280, 2000),
	})

	got := map[string]float64{}
	for _, s := range synth {
		got[s.Metric] = s.Value.(float64)
	}
	// Group A (infeed_only): gross:=net=175, scrap:=0. Net is NOT synthesized (it
	// was sensed and passes through the main loop untouched).
	if v, ok := got[grossA]; !ok || v != 175 {
		t.Errorf("group A gross: got %v (present=%v), want 175", v, ok)
	}
	if v, ok := got[scrapA]; !ok || v != 0 {
		t.Errorf("group A scrap: got %v (present=%v), want 0", v, ok)
	}
	if _, ok := got[netA]; ok {
		t.Errorf("group A net must NOT be synthesized (it was sensed): %v", got[netA])
	}
	// Group B (scrap_derived): scrap:=gross-net=20. gross/net pass through.
	if v, ok := got[scrapB]; !ok || v != 20 {
		t.Errorf("group B scrap: got %v (present=%v), want 20", v, ok)
	}
	if _, ok := got[grossB]; ok {
		t.Errorf("group B gross must NOT be synthesized: %v", got[grossB])
	}
}

// TestStage_HoldsPartialGroup proves a derivation with two sensed inputs does not
// fire until BOTH arrive — a partial group would look like a totalizer drop to
// Calc, so the stage holds until the batch carries every sensed role.
func TestStage_HoldsPartialGroup(t *testing.T) {
	const (
		grossB = "/L5/M2/Admin/ProdConsumedCount/7/Unit"
		netB   = "/L5/M2/Admin/ProdProcessedCount/7/Unit"
	)
	st := New([]Entry{
		{Suffix: grossB, Mode: ModeScrapDerived},
		{Suffix: netB, Mode: ModeScrapDerived},
	})
	// Only gross arrived — net (the other sensed input) is missing this batch.
	if synth := st.Process([]rawtag.RawTag{countTag(grossB, 300, 1000)}); len(synth) != 0 {
		t.Errorf("scrap_derived must hold until net also arrives, got %d synth", len(synth))
	}
}

// TestStage_EmptyWhenNoDeriveModes proves a tenant with only pass-through counts
// builds a no-op stage (zero hot-path cost).
func TestStage_EmptyWhenNoDeriveModes(t *testing.T) {
	st := New([]Entry{
		{Suffix: "/L5/M1/Admin/ProdConsumedCount/5/Unit", Mode: ModeFull},
		{Suffix: "/L5/M1/Admin/ProdProcessedCount/5/Unit", Mode: ""},
	})
	if !st.Empty() {
		t.Fatal("a stage with only full/empty modes must be Empty")
	}
	if synth := st.Process([]rawtag.RawTag{countTag("/L5/M1/Admin/ProdConsumedCount/5/Unit", 10, 1)}); synth != nil {
		t.Errorf("empty stage Process must be a no-op, got %v", synth)
	}
}
