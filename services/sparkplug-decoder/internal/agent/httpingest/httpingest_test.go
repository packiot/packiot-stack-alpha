package httpingest

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

const testKey = "s3cr3t-ingest-key"

// captureSink records every tag it is fed and simulates the resolver by
// treating any suffix NOT starting with "/unmapped" as accepted.
type captureSink struct {
	mu   sync.Mutex
	tags []rawtag.RawTag
}

func (c *captureSink) fn(tags []rawtag.RawTag) (accepted, total int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tags = append(c.tags, tags...)
	for _, t := range tags {
		if !strings.HasPrefix(t.Metric, "/unmapped") {
			accepted++
		}
	}
	return accepted, len(tags)
}

func (c *captureSink) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.tags)
}

func newTestServer(t *testing.T, scope string, sink Sink) http.Handler {
	t.Helper()
	outcomes := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "test_ingest_total"}, []string{"outcome"})
	srv := New(Config{APIKey: testKey, ScopeGroup: scope}, sink, outcomes, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return srv.Handler()
}

func post(t *testing.T, h http.Handler, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/tags", strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-Ingest-Key", key)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

const cpackBody = `{
  "group": "CPACK",
  "endpoint": "L8",
  "scan_ts": 1782849957000,
  "tags": [
    {"metric": "/L8/Status/StateCurrent", "value": 6, "long": true},
    {"metric": "/L8/Status/MachSpeed", "value": 118.4},
    {"metric": "/L8/Admin/ProdProcessedCount/51/Unit", "value": 40321}
  ]
}`

func TestIngest_Accepts202(t *testing.T) {
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	rec := post(t, h, testKey, cpackBody)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status: got %d, want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if sink.count() != 3 {
		t.Fatalf("sink tag count: got %d, want 3", sink.count())
	}
	if !strings.Contains(rec.Body.String(), `"accepted":3`) {
		t.Errorf("response body missing accepted count: %s", rec.Body.String())
	}
}

func TestIngest_BadKey401(t *testing.T) {
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	rec := post(t, h, "wrong-key", cpackBody)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status: got %d, want 401", rec.Code)
	}
	if sink.count() != 0 {
		t.Errorf("rejected request must not reach the sink; got %d tags", sink.count())
	}
}

func TestIngest_MissingKey401(t *testing.T) {
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	rec := post(t, h, "", cpackBody)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status: got %d, want 401", rec.Code)
	}
}

func TestIngest_WrongTenant403(t *testing.T) {
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	body := strings.Replace(cpackBody, `"group": "CPACK"`, `"group": "INCOPLAST"`, 1)
	rec := post(t, h, testKey, body)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status: got %d, want 403 (body=%s)", rec.Code, rec.Body.String())
	}
	if sink.count() != 0 {
		t.Errorf("out-of-scope request must not reach the sink; got %d tags", sink.count())
	}
}

func TestIngest_AbsentGroupAccepted(t *testing.T) {
	// A body with no `group` is accepted (single-tenant agent; tag_map drops
	// foreign metrics). Proves the scope guard doesn't break heartbeats.
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	body := strings.Replace(cpackBody, `"group": "CPACK",`, ``, 1)
	rec := post(t, h, testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status: got %d, want 202 (body=%s)", rec.Code, rec.Body.String())
	}
}

func TestIngest_EmptyBody400(t *testing.T) {
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	rec := post(t, h, testKey, "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400", rec.Code)
	}
}

func TestIngest_Undecodable400(t *testing.T) {
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	rec := post(t, h, testKey, `{"group":"CPACK","tags":[{"metric":"","value":1}]}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400 (empty metric suffix should fail decode)", rec.Code)
	}
}

func TestIngest_UnmappedTagsCounted(t *testing.T) {
	// A mix of mapped + unmapped tags → 202, accepted < total.
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn)
	body := `{"group":"CPACK","scan_ts":1,"tags":[
	  {"metric":"/L8/Status/MachSpeed","value":100},
	  {"metric":"/unmapped/Foo","value":1}
	]}`
	rec := post(t, h, testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status: got %d, want 202", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"accepted":1`) || !strings.Contains(rec.Body.String(), `"total":2`) {
		t.Errorf("want accepted:1 total:2, got %s", rec.Body.String())
	}
}

func TestIngest_ScopeDisabledWhenEmpty(t *testing.T) {
	// ScopeGroup="" disables the 403 path — any declared group is accepted.
	sink := &captureSink{}
	h := newTestServer(t, "", sink.fn)
	body := strings.Replace(cpackBody, `"group": "CPACK"`, `"group": "ANYTHING"`, 1)
	rec := post(t, h, testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status: got %d, want 202", rec.Code)
	}
}

func TestNew_PanicsWithoutKey(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("New must panic when APIKey is empty")
		}
	}()
	New(Config{APIKey: ""}, func([]rawtag.RawTag) (int, int) { return 0, 0 }, nil, slog.Default())
}
