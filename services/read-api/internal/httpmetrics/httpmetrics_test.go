package httpmetrics

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

func TestMiddleware_RecordsRouteTemplateAndStatus(t *testing.T) {
	reg := prometheus.NewRegistry()
	mux := http.NewServeMux()
	mux.HandleFunc("/ok", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/boom", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusInternalServerError) })
	h := New(reg)(mux)

	do := func(path string) { h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil)) }
	do("/ok")
	do("/ok")
	do("/boom")
	do("/nope") // no route → the mux 404s → route label must bucket as "unmatched"

	got := counts(t, reg)
	if got["/ok|200"] != 2 {
		t.Fatalf("/ok 200 = %d, want 2 (%v)", got["/ok|200"], got)
	}
	if got["/boom|500"] != 1 {
		t.Fatalf("/boom 500 = %d, want 1", got["/boom|500"])
	}
	if got["unmatched|404"] != 1 {
		t.Fatalf("unmatched 404 = %d, want 1 (%v)", got["unmatched|404"], got)
	}
}

func TestMiddleware_SkipsScrapeAndProbe(t *testing.T) {
	reg := prometheus.NewRegistry()
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {})
	h := New(reg)(mux)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/metrics", nil))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if n := len(counts(t, reg)); n != 0 {
		t.Fatalf("scrape/probe traffic must not be instrumented, got %d series", n)
	}
}

// counts maps route|status -> histogram sample count for the RED histogram.
func counts(t *testing.T, reg *prometheus.Registry) map[string]uint64 {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]uint64{}
	for _, mf := range mfs {
		if mf.GetName() != "http_request_duration_seconds" {
			continue
		}
		for _, m := range mf.GetMetric() {
			var route, status string
			for _, l := range m.GetLabel() {
				switch l.GetName() {
				case "route":
					route = l.GetValue()
				case "status":
					status = l.GetValue()
				}
			}
			out[route+"|"+status] = m.GetHistogram().GetSampleCount()
		}
	}
	return out
}
