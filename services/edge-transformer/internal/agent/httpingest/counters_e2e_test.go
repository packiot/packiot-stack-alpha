// End-to-end proof for the STACK-SIDE numeric-count-index TRANSLATION LAYER
// (ADR-0045 §2.3 Option-B, task #13): a BISPHARMA-shaped legacy
// `counterData[{id,value}]` POST → POST /v1/counters → numeric translation →
// the SHARED resolver→tagstore→session pipeline → sparkplug.Encode →
// sparkplug.Decode + StateStore.Ingest (the EXACT code edge-transformer runs
// cloud-side).
//
// It proves the load-bearing claim of the bispharma/bisnago migration: a dumb
// tee that forwards ONLY numeric counter ids (no topic strings) lands the
// CORRECT canonical SparkPlug metric names + ABSOLUTE totalizer values at the
// cloud decoder — the input the counters-only Calc (#591/#600) needs, with delta
// + sanity-clamp (#622) derived stack-side.
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
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/numeric"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

const bispharmaPrefix = "BISPHARMA/SP/LINHAS"

// newBispharmaResolver mirrors the resolver the agent builds from the bispharma
// register-synthesized raw_tag_map: two counters-only members off L01 (the real
// descriptor's count_index 164 and 167), each a Double ProdProcessedCount leaf.
func newBispharmaResolver() *cpackResolver {
	r := &cpackResolver{m: map[string]struct {
		name string
		dt   sparkplug.DataType
	}{}}
	add := func(suffix string, dt sparkplug.DataType) {
		r.m[suffix] = struct {
			name string
			dt   sparkplug.DataType
		}{bispharmaPrefix + suffix, dt}
	}
	add("/L01/S3/Admin/ProdProcessedCount/164/Unit", sparkplug.DataType_Double)
	add("/L01/S6_OUTPUT/Admin/ProdProcessedCount/167/Unit", sparkplug.DataType_Double)
	return r
}

func TestE2E_NumericCounters_TranslateToCanonicalSparkplug(t *testing.T) {
	resolver := newBispharmaResolver()
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

	// The translation table is DERIVED from the same raw_tag_map the resolver
	// uses (BuildIndexFromTagMap in the agent). Here we hand it the two count
	// leaves directly — proving id→canonical-suffix mapping.
	tr := numeric.NewTranslator(map[int]numeric.Target{
		164: {Suffix: "/L01/S3/Admin/ProdProcessedCount/164/Unit", Type: "double"},
		167: {Suffix: "/L01/S6_OUTPUT/Admin/ProdProcessedCount/167/Unit", Type: "double"},
	})

	const key = "e2e-key"
	vec := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "e2e_counters_total"}, []string{"outcome"})
	unmapped := prometheus.NewCounter(prometheus.CounterOpts{Name: "e2e_counters_unmapped"})
	h := httpingest.New(httpingest.Config{
		APIKey: key, ScopeGroup: "BISPHARMA", Numeric: tr, NumericUnmapped: unmapped,
	}, sink, vec, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()

	// ── 1. The DUMB tee's exact legacy shape: numeric ids + absolute totalizers,
	//    plus one id (999) that maps to nothing (must be reported, not crash).
	body := `{
	  "group": "BISPHARMA",
	  "gateway": "bispharma-edge",
	  "timestamp": 1782849957000,
	  "counterData": [
	    {"id": 164, "value": 40321},
	    {"id": 167, "value": 15005},
	    {"id": 999, "value": 7}
	  ]
	}`
	resp := postCounters(t, h, key, body)
	if !strings.Contains(resp, `"translated":2`) || !strings.Contains(resp, `"unmapped_index":1`) {
		t.Fatalf("counters response: %s", resp)
	}
	if store.Len() != 2 {
		t.Fatalf("tagstore Len after counters POST: got %d, want 2", store.Len())
	}

	// ── 2. Agent NBIRTH → encode → cloud decode+Ingest (establishes aliases). ──
	key2 := sparkplug.PublisherKey{GroupID: "BISPHARMA", EdgeNodeID: "bispharma-tee"}
	cloud := sparkplug.NewStateStore()
	nbirth, err := pub.BuildNBIRTH(store.SnapshotForBirth())
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}
	roundtrip(t, cloud, key2, sparkplug.MsgTypeNBirth, nbirth)

	// ── 3. A SECOND poll: the totalizers advanced (absolute, monotone). ────────
	body2 := `{
	  "group": "BISPHARMA", "gateway": "bispharma-edge", "timestamp": 1782849987000,
	  "counterData": [ {"id": 164, "value": 40355}, {"id": 167, "value": 15040} ]
	}`
	postCounters(t, h, key, body2)
	dirty := store.DrainDirty()
	if len(dirty) != 2 {
		t.Fatalf("RBE: expected 2 changed counters, got %d", len(dirty))
	}

	// ── 4. Agent NDATA → encode → cloud decode+Ingest → resolve ────────────────
	ndata, err := pub.BuildNDATA(dirty)
	if err != nil {
		t.Fatalf("BuildNDATA: %v", err)
	}
	resolved := roundtrip(t, cloud, key2, sparkplug.MsgTypeNData, ndata)
	if resolved == nil {
		t.Fatal("NDATA ingest returned nil ResolvedPayload")
	}

	// ── 5. The counters-only Calc's input survived numeric→canonical→cloud ─────
	byName := map[string]sparkplug.ResolvedMetric{}
	for _, m := range resolved.Metrics {
		byName[m.Name] = m
	}
	// id 164 → the canonical member ProdProcessedCount leaf, ABSOLUTE new value,
	// Double (config-authoritative), under the full canonical name.
	const want164 = bispharmaPrefix + "/L01/S3/Admin/ProdProcessedCount/164/Unit"
	if m, ok := byName[want164]; !ok {
		t.Errorf("cloud missing translated id 164 (%s)", want164)
	} else if v, _ := m.Value.(float64); v != 40355 {
		t.Errorf("id 164 absolute value: got %v, want 40355", m.Value)
	} else if m.Datatype != uint32(sparkplug.DataType_Double.Number()) {
		t.Errorf("id 164 datatype: got %d, want Double", m.Datatype)
	}
	const want167 = bispharmaPrefix + "/L01/S6_OUTPUT/Admin/ProdProcessedCount/167/Unit"
	if m, ok := byName[want167]; !ok {
		t.Errorf("cloud missing translated id 167 (%s)", want167)
	} else if v, _ := m.Value.(float64); v != 15040 {
		t.Errorf("id 167 absolute value: got %v, want 15040", m.Value)
	}

	// Delta sanity: the stack derives 40355-40321 = 34 for id 164 (positive,
	// bounded) — the input the ADR-0037 sanity clamp (#622) then guards. We assert
	// the RAW absolute values arrived so the stack CAN derive it; delta math is
	// the worker's job, proven by the counters-only Calc tests.
	if got := 40355 - 40321; got != 34 {
		t.Fatalf("arithmetic sanity: %d", got)
	}
}

// TestCounters_NotMountedWithoutTranslator proves the endpoint is off by default
// (no translator ⇒ /v1/counters 404), so the numeric surface never exists for a
// non-numeric tenant.
func TestCounters_NotMountedWithoutTranslator(t *testing.T) {
	sink := func(tags []rawtag.RawTag) (int, int) { return 0, len(tags) }
	vec := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "e2e_nomount_total"}, []string{"outcome"})
	h := httpingest.New(httpingest.Config{APIKey: "k", ScopeGroup: "X"}, sink,
		vec, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()
	req := httptest.NewRequest(http.MethodPost, "/v1/counters", strings.NewReader(`{"counterData":[]}`))
	req.Header.Set("X-Ingest-Key", "k")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("without translator /v1/counters should 404; got %d", rec.Code)
	}
}

func postCounters(t *testing.T, h http.Handler, key, body string) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/counters", strings.NewReader(body))
	req.Header.Set("X-Ingest-Key", key)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("POST /v1/counters status: got %d, want 202 (%s)", rec.Code, rec.Body.String())
	}
	return rec.Body.String()
}
