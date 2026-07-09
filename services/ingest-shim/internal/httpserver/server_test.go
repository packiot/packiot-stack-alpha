package httpserver

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/metrics"
)

// fakePublisher is a deterministic Publisher for tests. It records the last
// body it saw and returns a configurable error.
type fakePublisher struct {
	err      error
	healthy  bool
	lastBody []byte
	calls    int
}

func (f *fakePublisher) Publish(_ context.Context, body []byte) error {
	f.calls++
	f.lastBody = append([]byte(nil), body...)
	return f.err
}
func (f *fakePublisher) Healthy() bool { return f.healthy }

const testKey = "s3cr3t-key"

func newTestServer(pub Publisher) http.Handler {
	return New(Deps{
		APIKey:       testKey,
		MaxBodyBytes: 1 << 20,
		ScopeGroup:   "INCOPLAST",
		Publisher:    pub,
		Metrics:      metrics.New(),
		Logger:       discardLogger(),
	})
}

func do(t *testing.T, h http.Handler, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/ingest/sparkplug", strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-Ingest-Key", key)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

const incoplastBody = `{"timestamp":1782161858551,"gateway":"incoplast-nr","metrics":[{"name":"INCOPLAST/SP/EXTRUSION/EXT1/Status/StateCurrent","value":6}]}`

func TestIngest_NoKey_401(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	rec := do(t, newTestServer(pub), "", incoplastBody)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
	if pub.calls != 0 {
		t.Fatalf("publisher must not be called on auth failure, got %d calls", pub.calls)
	}
}

func TestIngest_WrongKey_401(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	rec := do(t, newTestServer(pub), "wrong-key", incoplastBody)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
	if pub.calls != 0 {
		t.Fatalf("publisher must not be called on auth failure")
	}
}

func TestIngest_NonIncoplastTopic_403(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	body := `{"metrics":[{"name":"CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent","value":6}]}`
	rec := do(t, newTestServer(pub), testKey, body)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", rec.Code)
	}
	if pub.calls != 0 {
		t.Fatalf("out-of-scope payload must not be published")
	}
}

func TestIngest_TopLevelTopic_ScopeGuard(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	// Explicit top-level topic field, non-Incoplast → 403.
	body := `{"topic":"ACME/x/y","metrics":[{"name":"INCOPLAST/a/b","value":1}]}`
	rec := do(t, newTestServer(pub), testKey, body)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("top-level topic should win the scope check; want 403, got %d", rec.Code)
	}
}

func TestIngest_Confirmed_202(t *testing.T) {
	pub := &fakePublisher{healthy: true} // err nil → confirmed
	rec := do(t, newTestServer(pub), testKey, incoplastBody)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d", rec.Code)
	}
	if pub.calls != 1 {
		t.Fatalf("want 1 publish call, got %d", pub.calls)
	}
	if string(pub.lastBody) != incoplastBody {
		t.Fatalf("body must be republished verbatim")
	}
}

func TestIngest_CaseInsensitiveGroup_202(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	body := `{"metrics":[{"name":"incoplast/sp/ext1/Status/StateCurrent","value":6}]}`
	rec := do(t, newTestServer(pub), testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("scope match must be case-insensitive; want 202, got %d", rec.Code)
	}
}

func TestIngest_PublishNack_503(t *testing.T) {
	pub := &fakePublisher{healthy: true, err: context.DeadlineExceeded}
	rec := do(t, newTestServer(pub), testKey, incoplastBody)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503 on publish failure, got %d", rec.Code)
	}
}

func TestIngest_EmptyBody_400(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	rec := do(t, newTestServer(pub), testKey, "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 on empty body, got %d", rec.Code)
	}
	if pub.calls != 0 {
		t.Fatalf("empty body must not be published")
	}
}

func TestIngest_Oversized_400(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	h := New(Deps{
		APIKey:       testKey,
		MaxBodyBytes: 64, // tiny cap for the test
		ScopeGroup:   "INCOPLAST",
		Publisher:    pub,
		Metrics:      metrics.New(),
		Logger:       discardLogger(),
	})
	big := `{"metrics":[{"name":"INCOPLAST/` + strings.Repeat("A", 200) + `"}]}`
	rec := do(t, h, testKey, big)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 on oversized body, got %d", rec.Code)
	}
	if pub.calls != 0 {
		t.Fatalf("oversized body must not be published")
	}
}

func TestIngest_UnparseableJSON_400(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	rec := do(t, newTestServer(pub), testKey, `{not json`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 on unparseable json, got %d", rec.Code)
	}
}

func TestHealthz(t *testing.T) {
	h := newTestServer(&fakePublisher{healthy: true})
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 when amqp up, got %d", rec.Code)
	}

	h = newTestServer(&fakePublisher{healthy: false})
	req = httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503 when amqp down, got %d", rec.Code)
	}
}

func TestFirstSegment(t *testing.T) {
	cases := map[string]string{
		"INCOPLAST/a/b": "INCOPLAST",
		"INCOPLAST":     "INCOPLAST",
		" INCOPLAST /x": "INCOPLAST",
		"":              "",
	}
	for in, want := range cases {
		if got := firstSegment(in); got != want {
			t.Errorf("firstSegment(%q)=%q want %q", in, got, want)
		}
	}
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
