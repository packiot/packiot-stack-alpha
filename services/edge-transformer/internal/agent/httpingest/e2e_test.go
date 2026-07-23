// End-to-end proof (ADR-0042 P1 VERIFY): a CPACK-shaped POST /v1/tags →
// httpingest → the SHARED resolver→tagstore→session pipeline → sparkplug.Encode
// → sparkplug.Decode + StateStore.Ingest (the EXACT code edge-transformer runs
// cloud-side). This is the "synthetic frame" the deploy's Sparkplug-inject step
// runs, but exercised through the NEW HTTP front-door instead of the MQTT
// subscriber — proving the tee path lands real CPACK metric names, aliases,
// datatypes, and values at the cloud decoder identically.
//
// It complements session.parity_test (which proves tagstore→cloud) by proving
// HTTP→tagstore, closing the full chain across the new code.
package httpingest_test

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/httpingest"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

const cpackPrefix = "CPACK/SC/LINHAS"

// cpackResolver mirrors the resolver cmd/sparkplug-agent builds from the CPACK
// raw_tag_map — the same 4 leaf topic kinds the Calc consumes for the L8 line.
type cpackResolver struct {
	m map[string]struct {
		name string
		dt   sparkplug.DataType
	}
}

func newCPACKResolver() *cpackResolver {
	r := &cpackResolver{m: map[string]struct {
		name string
		dt   sparkplug.DataType
	}{}}
	add := func(suffix string, dt sparkplug.DataType) {
		r.m[suffix] = struct {
			name string
			dt   sparkplug.DataType
		}{cpackPrefix + suffix, dt}
	}
	add("/L8/Admin/ProdProcessedCount/51/Unit", sparkplug.DataType_Double)
	add("/L8/Status/MachSpeed", sparkplug.DataType_Double)
	add("/L8/Status/StateCurrent", sparkplug.DataType_Int64)
	add("/L8/Status/Parameter30700", sparkplug.DataType_String)
	return r
}

func (r *cpackResolver) Resolve(suffix string) (string, sparkplug.DataType, bool) {
	e, ok := r.m[suffix]
	if !ok {
		return "", 0, false
	}
	return e.name, e.dt, true
}

func TestE2E_CPACKPostToCloudResolve(t *testing.T) {
	resolver := newCPACKResolver()
	aliases := aliasmap.New()
	pub := session.New(resolver, aliases)
	store := tagstore.New()

	// The SHARED sink — identical to cmd/sparkplug-agent's `ingest` closure.
	sink := func(tags []rawtag.RawTag) (accepted, total int) {
		for _, tg := range tags {
			if _, _, ok := resolver.Resolve(tg.Metric); !ok {
				continue
			}
			store.Apply(tg)
			accepted++
		}
		return accepted, len(tags)
	}

	const key = "e2e-key"
	vec := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "e2e_total"}, []string{"outcome"})
	h := httpingest.New(httpingest.Config{APIKey: key, ScopeGroup: "CPACK"}, sink,
		vec, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()

	// ── 1. CPACK-shaped POST /v1/tags (the tee's exact envelope shape) ────
	body := `{
	  "group": "CPACK",
	  "endpoint": "L8",
	  "scan_ts": 1782849957000,
	  "tags": [
	    {"metric": "/L8/Status/MachSpeed", "value": 118.4},
	    {"metric": "/L8/Admin/ProdProcessedCount/51/Unit", "value": 40321, "long": true},
	    {"metric": "/L8/Status/StateCurrent", "value": 6, "long": true},
	    {"metric": "/L8/Status/Parameter30700", "value": "51"}
	  ]
	}`
	postTags(t, h, key, body)
	if store.Len() != 4 {
		t.Fatalf("tagstore Len after POST: got %d, want 4", store.Len())
	}

	// ── 2. Agent NBIRTH → encode → cloud decode+Ingest (establishes aliases).
	//    A BIRTH returns nil ResolvedPayload by design — it registers the
	//    name↔alias table; data resolution surfaces on the following NDATA.
	key2 := sparkplug.PublisherKey{GroupID: "CPACK", EdgeNodeID: "cpack-tee"}
	cloud := sparkplug.NewStateStore()
	nbirth, err := pub.BuildNBIRTH(store.SnapshotForBirth())
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}
	roundtrip(t, cloud, key2, sparkplug.MsgTypeNBirth, nbirth)

	// ── 3. A SECOND CPACK POST changes 2 tags (report-by-exception) ───────
	body2 := `{
	  "group": "CPACK",
	  "endpoint": "L8",
	  "scan_ts": 1782849962000,
	  "tags": [
	    {"metric": "/L8/Status/MachSpeed", "value": 121.0},
	    {"metric": "/L8/Admin/ProdProcessedCount/51/Unit", "value": 40355, "long": true},
	    {"metric": "/L8/Status/StateCurrent", "value": 6, "long": true},
	    {"metric": "/L8/Status/Parameter30700", "value": "51"}
	  ]
	}`
	postTags(t, h, key, body2)
	dirty := store.DrainDirty()
	if len(dirty) != 2 {
		t.Fatalf("RBE: expected 2 changed tags, got %d", len(dirty))
	}

	// ── 4. Agent NDATA → encode → cloud decode+Ingest → resolve ───────────
	ndata, err := pub.BuildNDATA(dirty)
	if err != nil {
		t.Fatalf("BuildNDATA: %v", err)
	}
	resolved := roundtrip(t, cloud, key2, sparkplug.MsgTypeNData, ndata)
	if resolved == nil {
		t.Fatal("NDATA ingest returned nil ResolvedPayload")
	}

	// ── 5. The Calc's inputs survived the full HTTP→cloud chain ───────────
	byName := map[string]sparkplug.ResolvedMetric{}
	for _, m := range resolved.Metrics {
		byName[m.Name] = m
	}
	// MachSpeed (min-speed downtime input) — Double, changed value.
	if m, ok := byName[cpackPrefix+"/L8/Status/MachSpeed"]; !ok {
		t.Error("cloud missing L8 MachSpeed")
	} else if v, _ := m.Value.(float64); v != 121.0 {
		t.Errorf("MachSpeed value: got %v, want 121.0", m.Value)
	}
	// ProdProcessedCount (production counter) — Double (config-authoritative
	// over the wire's `long` hint), changed value.
	if m, ok := byName[cpackPrefix+"/L8/Admin/ProdProcessedCount/51/Unit"]; !ok {
		t.Error("cloud missing L8 ProdProcessedCount")
	} else if v, _ := m.Value.(float64); v != 40355 {
		t.Errorf("ProdProcessedCount value: got %v (%T), want 40355", m.Value, m.Value)
	} else if m.Datatype != uint32(sparkplug.DataType_Double.Number()) {
		t.Errorf("ProdProcessedCount datatype: got %d, want Double", m.Datatype)
	}
}

func postTags(t *testing.T, h http.Handler, key, body string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/tags", strings.NewReader(body))
	req.Header.Set("X-Ingest-Key", key)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("POST status: got %d, want 202 (%s)", rec.Code, rec.Body.String())
	}
}

func roundtrip(t *testing.T, ss *sparkplug.StateStore, key sparkplug.PublisherKey, msgType string, p *sparkplug.Payload) *sparkplug.ResolvedPayload {
	t.Helper()
	frame, err := sparkplug.Encode(p)
	if err != nil {
		t.Fatalf("encode %s: %v", msgType, err)
	}
	decoded, err := sparkplug.Decode(frame)
	if err != nil {
		t.Fatalf("decode %s: %v", msgType, err)
	}
	resolved, err := ss.Ingest(key, msgType, decoded)
	if err != nil {
		t.Fatalf("ingest %s: %v", msgType, err)
	}
	return resolved
}
