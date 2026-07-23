// The CORRECTNESS GATE (ADR-0042 P0 gate). In-process, DEFAULT `go test`, no
// external deps: raw JSON tags → tagstore → session.Publisher build
// NBIRTH+NDATA → sparkplug.Encode → sparkplug.Decode + StateStore.Ingest →
// assert ResolvedPayload.Metrics == expected.
//
// This proves the agent's encode is EXACTLY what the production cloud decoder
// (internal/sparkplug StateStore — the same code edge-transformer runs)
// resolves: names, aliases, datatypes, and values all survive the full
// producer→wire→consumer round trip. If this is green, a raw-tag stream
// produces valid SparkPlug the cloud decodes identically (the P0 gate).
package session_test

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

const parityPrefix = "CPACK/SC/LINHAS/L5/BREYER"

// mapResolver is the test's session.Resolver — the same shape cmd's resolver
// builds from raw_tag_map.
type mapResolver struct {
	m map[string]struct {
		name string
		dt   sparkplug.DataType
	}
}

func newMapResolver() *mapResolver {
	r := &mapResolver{m: map[string]struct {
		name string
		dt   sparkplug.DataType
	}{}}
	add := func(suffix string, dt sparkplug.DataType) {
		r.m[suffix] = struct {
			name string
			dt   sparkplug.DataType
		}{parityPrefix + suffix, dt}
	}
	add("/Admin/ProdProcessedCount/1/Unit", sparkplug.DataType_Int64)
	add("/Status/MachSpeed", sparkplug.DataType_Double)
	add("/Status/PoNumber", sparkplug.DataType_String)
	add("/Status/StateCurrent", sparkplug.DataType_Int64)
	return r
}

func (r *mapResolver) Resolve(suffix string) (string, sparkplug.DataType, bool) {
	e, ok := r.m[suffix]
	if !ok {
		return "", 0, false
	}
	return e.name, e.dt, true
}

func TestParity_RawJSONToCloudResolve(t *testing.T) {
	resolver := newMapResolver()
	aliases := aliasmap.New()
	pub := session.New(resolver, aliases)
	store := tagstore.New()

	key := sparkplug.PublisherKey{GroupID: "CPACK", EdgeNodeID: "sparkplug-agent"}
	cloud := sparkplug.NewStateStore()

	// ── 1. Raw JSON envelope (the Tier-1 contract) → decode → RBE-apply ──
	birthJSON := []byte(`{
	  "endpoint": "L5_BREYER",
	  "scan_ts": 1782849957000,
	  "tags": [
	    {"metric": "/Status/MachSpeed", "value": 12.5, "q": true},
	    {"metric": "/Admin/ProdProcessedCount/1/Unit", "value": 42, "long": true},
	    {"metric": "/Status/StateCurrent", "value": 6, "long": true},
	    {"metric": "/Status/PoNumber", "value": "PO-1", "q": true}
	  ]
	}`)
	tags, err := rawtag.Decode(birthJSON)
	if err != nil {
		t.Fatalf("decode birth JSON: %v", err)
	}
	for _, tg := range tags {
		store.Apply(tg)
	}

	// ── 2. Build NBIRTH → encode → decode → Ingest at the cloud ──────────
	nbirth, err := pub.BuildNBIRTH(store.SnapshotForBirth())
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}
	if got := nbirth.GetSeq(); got != 0 {
		t.Fatalf("NBIRTH seq: got %d, want 0 (spec: birth resets seq)", got)
	}
	roundtripIngest(t, cloud, key, sparkplug.MsgTypeNBirth, nbirth)

	// ── 3. Change 2 tags; unchanged tags must NOT reach NDATA (RBE) ──────
	dataJSON := []byte(`{
	  "endpoint": "L5_BREYER",
	  "scan_ts": 1782849962000,
	  "tags": [
	    {"metric": "/Status/MachSpeed", "value": 15.0, "q": true},
	    {"metric": "/Admin/ProdProcessedCount/1/Unit", "value": 50, "long": true},
	    {"metric": "/Status/StateCurrent", "value": 6, "long": true},
	    {"metric": "/Status/PoNumber", "value": "PO-1", "q": true}
	  ]
	}`)
	tags2, err := rawtag.Decode(dataJSON)
	if err != nil {
		t.Fatalf("decode data JSON: %v", err)
	}
	for _, tg := range tags2 {
		store.Apply(tg)
	}
	dirty := store.DrainDirty()
	if len(dirty) != 2 {
		t.Fatalf("RBE: expected 2 changed tags, got %d (%v)", len(dirty), suffixes(dirty))
	}

	// ── 4. Build NDATA → encode → decode → Ingest → resolve ──────────────
	ndata, err := pub.BuildNDATA(dirty)
	if err != nil {
		t.Fatalf("BuildNDATA: %v", err)
	}
	if got := ndata.GetSeq(); got != 1 {
		t.Fatalf("NDATA seq: got %d, want 1 (0→1 after birth)", got)
	}
	resolved := roundtripIngest(t, cloud, key, sparkplug.MsgTypeNData, ndata)
	if resolved == nil {
		t.Fatal("NDATA ingest returned nil ResolvedPayload")
	}

	// ── 5. Assert resolved metrics == expected {name, alias, datatype, value}
	// dirty is sorted by suffix: ProdProcessedCount(<)/Status/MachSpeed.
	want := []sparkplug.ResolvedMetric{
		{
			Name:     parityPrefix + "/Admin/ProdProcessedCount/1/Unit",
			Alias:    1, // allocated 1st in snapshot (suffix-sorted) order
			Datatype: uint32(sparkplug.DataType_Int64.Number()),
			Value:    uint64(50),
		},
		{
			Name:     parityPrefix + "/Status/MachSpeed",
			Alias:    2,
			Datatype: uint32(sparkplug.DataType_Double.Number()),
			Value:    float64(15.0),
		},
	}
	if len(resolved.Metrics) != len(want) {
		t.Fatalf("resolved metric count: got %d, want %d", len(resolved.Metrics), len(want))
	}
	for i, w := range want {
		g := resolved.Metrics[i]
		if g.Name != w.Name {
			t.Errorf("metric[%d].name: got %q, want %q", i, g.Name, w.Name)
		}
		if g.Alias != w.Alias {
			t.Errorf("metric[%d].alias: got %d, want %d", i, g.Alias, w.Alias)
		}
		if g.Datatype != w.Datatype {
			t.Errorf("metric[%d].datatype: got %d, want %d (cloud falls back to BIRTH datatype)", i, g.Datatype, w.Datatype)
		}
		if g.Value != w.Value {
			t.Errorf("metric[%d].value: got %v (%T), want %v (%T)", i, g.Value, g.Value, w.Value, w.Value)
		}
	}
}

// roundtripIngest encodes the payload, decodes it (as the cloud subscriber
// does over the wire), and Ingests it into the StateStore.
func roundtripIngest(t *testing.T, ss *sparkplug.StateStore, key sparkplug.PublisherKey, msgType string, p *sparkplug.Payload) *sparkplug.ResolvedPayload {
	t.Helper()
	body, err := sparkplug.Encode(p)
	if err != nil {
		t.Fatalf("encode %s: %v", msgType, err)
	}
	decoded, err := sparkplug.Decode(body)
	if err != nil {
		t.Fatalf("decode %s: %v", msgType, err)
	}
	resolved, err := ss.Ingest(key, msgType, decoded)
	if err != nil {
		t.Fatalf("ingest %s: %v", msgType, err)
	}
	return resolved
}

func suffixes(tags []rawtag.RawTag) []string {
	out := make([]string, len(tags))
	for i, t := range tags {
		out[i] = t.Metric
	}
	return out
}
