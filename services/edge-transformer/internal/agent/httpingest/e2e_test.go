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
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tenantprofile"
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

// newCPACKLineResolver mirrors the resolver the agent builds for CPACK's L5
// LINE from the register-synthesized raw_tag_map (metric_templates.line) —
// crucially it carries the NUMBERED /Status/Parameter30700 entry (the bare
// /Status/Parameter is intentionally NOT a key: the wire never sends it).
func newCPACKLineResolver() *cpackResolver {
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
	add("/L5/Status/MachSpeed", sparkplug.DataType_Double)
	add("/L5/Status/StateCurrent", sparkplug.DataType_Int64)
	add("/L5/Status/Parameter30700", sparkplug.DataType_String)
	return r
}

// TestE2E_ParameterDecomposition_FeedsPhase9 is the load-bearing proof for the
// #54 follow-up: real CPACK sends a BARE ".../Status/Parameter" whose PackML id
// (30700) rides in the tag's `param` field (verified against prod). With
// AGENT_PARAM_DECOMPOSITION on, the agent rewrites it to the canonical numbered
// leaf BEFORE the allowlist lookup, so the metric lands at the cloud decoder as
// "CPACK/SC/LINHAS/L5/Status/Parameter30700" — the EXACT name
// cmd/edge-transformer seedFromMetric HasSuffix-matches to seed the line-machines
// CSV that Phase-9 line aggregation reads. Without decomposition the bare tag is
// unmapped → dropped and Phase-9 never fires.
func TestE2E_ParameterDecomposition_FeedsPhase9(t *testing.T) {
	resolver := newCPACKLineResolver()
	aliases := aliasmap.New()
	pub := session.New(resolver, aliases)
	store := tagstore.New()

	// The decomposer profile — the parameter_decomposition rule from
	// docs/clients/cpack-profile.yaml.
	prof := &tenantprofile.Profile{
		Tenant:       "CPACK",
		TenantPrefix: cpackPrefix,
		ParameterDecomposition: tenantprofile.ParameterDecomposition{
			SourceLeaf: "/Status/Parameter",
			Params: []tenantprofile.DecomposedParam{
				{ID: 30700, Leaf: "/Status/Parameter30700", AppliesTo: tenantprofile.ClassLine},
			},
		},
	}

	// The SHARED sink — identical to cmd/sparkplug-agent's `ingest` closure WITH
	// AGENT_PARAM_DECOMPOSITION enabled (decompose, then resolve, then apply).
	sink := func(tags []rawtag.RawTag) (accepted, total int) {
		for _, tg := range tags {
			if tg.ParamID != 0 {
				if ns, ok := prof.DecomposeParameterSuffix(tg.Metric, tg.ParamID); ok {
					tg.Metric = ns
				}
			}
			if _, _, ok := resolver.Resolve(tg.Metric); !ok {
				continue
			}
			store.Apply(tg)
			accepted++
		}
		return accepted, len(tags)
	}

	const key = "e2e-key"
	vec := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "e2e_decomp_total"}, []string{"outcome"})
	h := httpingest.New(httpingest.Config{APIKey: key, ScopeGroup: "CPACK"}, sink,
		vec, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()

	// ── 1. Baseline: WITHOUT the `param` id, the bare Parameter is unmapped ──
	// (proves the tag does not accidentally resolve as-is).
	preLen := store.Len()
	postTags(t, h, key, `{
	  "group": "CPACK", "endpoint": "L5", "scan_ts": 1782849957000,
	  "tags": [ {"metric": "/L5/Status/Parameter", "value": "47,53,54"} ]
	}`)
	if store.Len() != preLen {
		t.Fatalf("bare Parameter (no param id) must be unmapped/dropped; store grew %d→%d", preLen, store.Len())
	}

	// ── 2. WITH param:30700 → decomposed → mapped → applied ─────────────────
	postTags(t, h, key, `{
	  "group": "CPACK", "endpoint": "L5", "scan_ts": 1782849957000,
	  "tags": [
	    {"metric": "/L5/Status/MachSpeed", "value": 118.4},
	    {"metric": "/L5/Status/StateCurrent", "value": 6, "long": true},
	    {"metric": "/L5/Status/Parameter", "value": "47,53,54", "param": 30700}
	  ]
	}`)
	if store.Len() != 3 {
		t.Fatalf("after decomposed POST: store Len got %d, want 3", store.Len())
	}

	// ── 3. NBIRTH → encode → cloud decode+Ingest → the numbered name lands ──
	key2 := sparkplug.PublisherKey{GroupID: "CPACK", EdgeNodeID: "cpack-tee"}
	cloud := sparkplug.NewStateStore()
	nbirth, err := pub.BuildNBIRTH(store.SnapshotForBirth())
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}
	roundtrip(t, cloud, key2, sparkplug.MsgTypeNBirth, nbirth)

	// ── 4. Change the CSV → NDATA → resolve, and assert Phase-9's input ─────
	postTags(t, h, key, `{
	  "group": "CPACK", "endpoint": "L5", "scan_ts": 1782849962000,
	  "tags": [ {"metric": "/L5/Status/Parameter", "value": "47,53", "param": 30700} ]
	}`)
	dirty := store.DrainDirty()
	ndata, err := pub.BuildNDATA(dirty)
	if err != nil {
		t.Fatalf("BuildNDATA: %v", err)
	}
	resolved := roundtrip(t, cloud, key2, sparkplug.MsgTypeNData, ndata)
	if resolved == nil {
		t.Fatal("NDATA ingest returned nil ResolvedPayload")
	}

	// The decomposed metric arrives at the cloud under the EXACT name the Calc's
	// Parameter30700 seed keys on — with the CSV value Phase-9 splits on ",".
	const wantName = cpackPrefix + "/L5/Status/Parameter30700"
	var got *sparkplug.ResolvedMetric
	for i := range resolved.Metrics {
		if resolved.Metrics[i].Name == wantName {
			got = &resolved.Metrics[i]
		}
		// The bare, undecomposed name must NEVER appear on the wire.
		if resolved.Metrics[i].Name == cpackPrefix+"/L5/Status/Parameter" {
			t.Errorf("bare Parameter leaked to cloud: %q", resolved.Metrics[i].Name)
		}
	}
	if got == nil {
		t.Fatalf("cloud missing decomposed %q (Phase-9's line-machines CSV input)", wantName)
	}
	if !strings.HasSuffix(got.Name, "/Status/Parameter30700") {
		t.Errorf("decomposed name %q must match seedFromMetric HasSuffix(/Status/Parameter30700)", got.Name)
	}
	if v, _ := got.Value.(string); v != "47,53" {
		t.Errorf("Parameter30700 CSV value: got %v (%T), want \"47,53\"", got.Value, got.Value)
	}
}
