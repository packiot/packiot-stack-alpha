// Birth-completeness tests (CPACK 2026-08-13 line-count regression fix).
//
// Root cause proven live: the cloud edge-transformer could only decode the lines
// that happened to be aliased at BIRTH time. A sparse line idle at connect never
// got an alias in the seen-only snapshot, so when it finally reported, its NDATA
// referenced an alias the cloud StateStore never registered → ErrUnknownAlias →
// the whole line's data vanished. AGENT_BIRTH_ALL_MAPPED restores the invariant:
// EVERY mapped metric is birthed with a stable alias, always.
//
// These tests exercise the REAL code path (mapResolver implements
// session.AllResolver, exactly like cmd's resolver) and prove:
//
//	(a) birth-all NBIRTH includes ALL mapped metrics, incl. never-seen ones;
//	(b) a sparse metric's later NDATA resolves against the pre-birthed alias;
//	(c) birth-completeness injects NO spurious dirty/NDATA for unseen metrics;
//	(d) flag OFF is byte-identical to the pre-fix behaviour;
//	(e) alias allocation is deterministic across constructions + arrival orders.
package session_test

import (
	"bytes"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// The four suffixes newMapResolver knows, and their full names, in the stable
// suffix-sorted order AllMapped guarantees.
const (
	sfxCount = "/Admin/ProdProcessedCount/1/Unit"
	sfxSpeed = "/Status/MachSpeed"
	sfxPO    = "/Status/PoNumber"
	sfxState = "/Status/StateCurrent"
)

// aliasByName pulls the name→alias table out of an NBIRTH payload (skipping the
// nameless/aliasless bdSeq trailer).
func aliasByName(p *sparkplug.Payload) map[string]uint64 {
	out := map[string]uint64{}
	for _, m := range p.GetMetrics() {
		if m.GetName() == "bdSeq" || m.Alias == nil {
			continue
		}
		out[m.GetName()] = m.GetAlias()
	}
	return out
}

func metricByName(p *sparkplug.Payload, name string) *sparkplug.Metric {
	for _, m := range p.GetMetrics() {
		if m.GetName() == name {
			return m
		}
	}
	return nil
}

// birthAllPub builds a Publisher with birth-completeness on and a fresh alias table.
func birthAllPub() *session.Publisher {
	return session.New(newMapResolver(), aliasmap.New(), session.WithBirthAllMapped(true))
}

// (a) Birth-all NBIRTH carries every mapped metric — including the three the
// snapshot never saw — each with a stable, suffix-sorted alias. The single seen
// metric carries its real value; the unseen ones are explicit SparkPlug nulls.
func TestBirthAllMapped_CoversFullMap(t *testing.T) {
	pub := birthAllPub()
	pub.NewConnection()

	// Only MachSpeed has ever reported — the count/PO/state lines were idle.
	nb, err := pub.BuildNBIRTH([]rawtag.RawTag{rt(sfxSpeed, 12.5)})
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}

	names := aliasByName(nb)
	want := []string{
		parityPrefix + sfxCount,
		parityPrefix + sfxSpeed,
		parityPrefix + sfxPO,
		parityPrefix + sfxState,
	}
	for _, n := range want {
		if _, ok := names[n]; !ok {
			t.Errorf("NBIRTH missing mapped metric %q — birth is not complete", n)
		}
	}
	if len(names) != len(want) {
		t.Errorf("NBIRTH birthed %d mapped metrics, want %d (%v)", len(names), len(want), names)
	}

	// Aliases are allocated in suffix-sorted order → count=1, speed=2, po=3, state=4.
	for i, n := range want {
		if got := names[n]; got != uint64(i+1) {
			t.Errorf("alias(%q) = %d, want %d (suffix-sorted allocation)", n, got, i+1)
		}
	}

	// The seen metric carries its value; the unseen ones are is_null with no value.
	speed := metricByName(nb, parityPrefix+sfxSpeed)
	if speed.GetIsNull() {
		t.Error("seen metric MachSpeed marked is_null — should carry its value")
	}
	if dv, ok := speed.GetValue().(*sparkplug.Metric_DoubleValue); !ok || dv.DoubleValue != 12.5 {
		t.Errorf("seen metric MachSpeed value = %v, want 12.5", speed.GetValue())
	}
	for _, sfx := range []string{sfxCount, sfxPO, sfxState} {
		m := metricByName(nb, parityPrefix+sfx)
		if !m.GetIsNull() {
			t.Errorf("unseen metric %q is not is_null — a phantom value could leak", sfx)
		}
		if m.GetValue() != nil {
			t.Errorf("unseen metric %q carries a value oneof %v — must be null-only", sfx, m.GetValue())
		}
	}
}

// (b) End-to-end: a sparse count line idle at birth, then reporting, resolves at
// the cloud StateStore against the alias frozen at NBIRTH — no ErrUnknownAlias.
// This is the exact failure the regression exhibited, now closed.
func TestBirthAllMapped_SparseLineNDATAResolves(t *testing.T) {
	resolver := newMapResolver()
	aliases := aliasmap.New()
	pub := session.New(resolver, aliases, session.WithBirthAllMapped(true))
	store := tagstore.New()
	ss := sparkplug.NewStateStore()
	key := sparkplug.PublisherKey{GroupID: "CPACK", EdgeNodeID: "edge"}

	pub.NewConnection()

	// At connect only MachSpeed had reported. Birth from the store snapshot.
	store.Apply(rt(sfxSpeed, 12.5))
	nb, err := pub.BuildNBIRTH(store.SnapshotForBirth())
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}
	roundtripIngest(t, ss, key, sparkplug.MsgTypeNBirth, nb) // cloud now has ALL aliases

	// The sparse count line finally reports its (static) totalizer.
	changed := store.Apply(rt(sfxCount, 4200.0))
	if !changed {
		t.Fatal("first count reading should mark dirty")
	}
	dirty := store.DrainDirty()

	// Its alias was frozen at birth → no rebirth needed, and NDATA is decodable.
	if pub.NeedsRebirth(dirty) {
		t.Fatal("sparse count line still needs a rebirth — its alias was not pre-birthed")
	}
	nd, err := pub.BuildNDATA(dirty)
	if err != nil {
		t.Fatalf("BuildNDATA: %v", err)
	}
	resolved := roundtripIngest(t, ss, key, sparkplug.MsgTypeNData, nd)
	if resolved == nil || len(resolved.Metrics) != 1 {
		t.Fatalf("NDATA resolved = %v, want exactly the count metric", resolved)
	}
	got := resolved.Metrics[0]
	if got.Name != parityPrefix+sfxCount {
		t.Errorf("resolved name = %q, want %q", got.Name, parityPrefix+sfxCount)
	}
	if v, ok := got.Value.(uint64); !ok || v != 4200 {
		t.Errorf("resolved value = %v, want 4200", got.Value)
	}
}

// (c) Birth-completeness must not manufacture data: the never-seen metrics are
// birthed as nulls but the tagstore stays pure, so DrainDirty (the NDATA source)
// only ever contains metrics that were actually Apply'd. No spurious NDATA.
func TestBirthAllMapped_NoSpuriousNDATA(t *testing.T) {
	pub := birthAllPub()
	store := tagstore.New()
	pub.NewConnection()

	store.Apply(rt(sfxSpeed, 12.5)) // exactly one real reading
	if _, err := pub.BuildNBIRTH(store.SnapshotForBirth()); err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}

	// The birth touched all 4 aliases, but the store only knows the 1 applied tag.
	dirty := store.DrainDirty()
	if len(dirty) != 0 {
		t.Errorf("dirty set after a birth-consuming drain = %v, want empty", suffixes(dirty))
	}
	// A subsequent unrelated tick must not conjure NDATA for the unseen metrics.
	store.Apply(rt(sfxSpeed, 12.5)) // same value → RBE no-op, not dirty
	if d := store.DrainDirty(); len(d) != 0 {
		t.Errorf("unchanged reading produced dirty %v — RBE/birth interaction leaked", suffixes(d))
	}
}

// (d) Flag OFF is byte-identical to a default-constructed Publisher: the fix is a
// pure no-op until AGENT_BIRTH_ALL_MAPPED is set.
func TestBirthAllMapped_OffIsByteIdentical(t *testing.T) {
	snap := []rawtag.RawTag{rt(sfxSpeed, 12.5), rt(sfxCount, 4200.0)}

	def := session.New(newMapResolver(), aliasmap.New()) // pre-fix construction
	def.NewConnection()
	nbDefault, err := def.BuildNBIRTH(snap)
	if err != nil {
		t.Fatalf("default BuildNBIRTH: %v", err)
	}

	off := session.New(newMapResolver(), aliasmap.New(), session.WithBirthAllMapped(false))
	off.NewConnection()
	nbOff, err := off.BuildNBIRTH(snap)
	if err != nil {
		t.Fatalf("flag-off BuildNBIRTH: %v", err)
	}

	bDefault, _ := sparkplug.Encode(nbDefault)
	bOff, _ := sparkplug.Encode(nbOff)
	if !bytes.Equal(bDefault, bOff) {
		t.Errorf("flag-off NBIRTH differs from default: %d vs %d bytes", len(bOff), len(bDefault))
	}
	// And flag-off must birth ONLY the seen metrics (no full-map expansion).
	if names := aliasByName(nbOff); len(names) != 2 {
		t.Errorf("flag-off birthed %d metrics, want 2 (seen-only): %v", len(names), names)
	}
}

// (e) Determinism: two independent Publishers, seeing DIFFERENT tags in different
// orders, must allocate the SAME name→alias table under birth-all — the property
// that keeps aliases stable across an agent restart.
func TestBirthAllMapped_AliasDeterminism(t *testing.T) {
	pubA := birthAllPub()
	pubA.NewConnection()
	nbA, err := pubA.BuildNBIRTH([]rawtag.RawTag{rt(sfxSpeed, 1.0)}) // A saw speed first
	if err != nil {
		t.Fatalf("A BuildNBIRTH: %v", err)
	}

	pubB := birthAllPub()
	pubB.NewConnection()
	nbB, err := pubB.BuildNBIRTH([]rawtag.RawTag{rt(sfxPO, "PO-9")}) // B saw a different tag first
	if err != nil {
		t.Fatalf("B BuildNBIRTH: %v", err)
	}

	a, b := aliasByName(nbA), aliasByName(nbB)
	if len(a) != len(b) {
		t.Fatalf("alias table sizes differ: %d vs %d", len(a), len(b))
	}
	for name, av := range a {
		if bv, ok := b[name]; !ok || av != bv {
			t.Errorf("alias(%q): A=%d B=%d — not deterministic", name, av, bv)
		}
	}
}
