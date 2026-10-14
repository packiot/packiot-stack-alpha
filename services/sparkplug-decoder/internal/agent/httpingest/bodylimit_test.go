package httpingest

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/numeric"
)

// A body over MaxBodyBytes is 413 (not 400) on both front-door routes, with
// the usual {"error":"payload too large"} body, and nothing reaches the sink.
func TestIngest_OversizedBody413(t *testing.T) {
	sink := &captureSink{}
	outcomes := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "test_bodylimit_total"}, []string{"outcome"})
	h := New(Config{
		APIKey: testKey, ScopeGroup: "CPACK", MaxBodyBytes: 64,
		Numeric: numeric.NewTranslator(map[int]numeric.Target{}),
	}, sink.fn, outcomes, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()

	big := `{"group":"CPACK","tags":[{"metric":"/L8/` + strings.Repeat("A", 200) + `","value":1}]}`
	for _, path := range []string{"/v1/tags", "/v1/counters"} {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(big))
		req.Header.Set("X-Ingest-Key", testKey)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusRequestEntityTooLarge {
			t.Errorf("%s: status %d, want 413 (body %q)", path, rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), "payload too large") {
			t.Errorf("%s: body %q, want payload too large", path, rec.Body.String())
		}
	}
	if sink.count() != 0 {
		t.Fatalf("oversized bodies must not reach the sink, got %d tags", sink.count())
	}
}
