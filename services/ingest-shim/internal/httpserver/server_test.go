package httpserver

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/metrics"
)

// fakePublisher is a deterministic Publisher for tests. It records every body
// it saw (fan-out publishes more than once) and returns a configurable error.
type fakePublisher struct {
	err      error
	healthy  bool
	lastBody []byte
	bodies   [][]byte
	calls    int
}

func (f *fakePublisher) Publish(_ context.Context, body []byte) error {
	f.calls++
	f.lastBody = append([]byte(nil), body...)
	f.bodies = append(f.bodies, append([]byte(nil), body...))
	return f.err
}

// sourceTypeOf extracts the top-level source_type from a published body.
func sourceTypeOf(t *testing.T, body []byte) string {
	t.Helper()
	var m struct {
		SourceType string `json:"source_type"`
	}
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("published body not valid JSON: %v", err)
	}
	return m.SourceType
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
	// newTestServer sets no FanoutSourceTypes → single-publish default.
	rec := do(t, newTestServer(pub), testKey, incoplastBody)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d", rec.Code)
	}
	if pub.calls != 1 {
		t.Fatalf("want 1 publish call, got %d", pub.calls)
	}
	// Default flow stamps source_type "" (F1) and preserves the payload.
	if got := sourceTypeOf(t, pub.lastBody); got != "" {
		t.Fatalf("default publish must carry source_type \"\", got %q", got)
	}
	if !strings.Contains(string(pub.lastBody), "incoplast-nr") {
		t.Fatalf("published body must preserve original fields, got %s", pub.lastBody)
	}
}

func TestIngest_Fanout_ThreeFlows(t *testing.T) {
	pub := &fakePublisher{healthy: true}
	h := New(Deps{
		APIKey:            testKey,
		MaxBodyBytes:      1 << 20,
		ScopeGroup:        "INCOPLAST",
		FanoutSourceTypes: []string{"", "go", "refactored"},
		Publisher:         pub,
		Metrics:           metrics.New(),
		Logger:            discardLogger(),
	})
	rec := do(t, h, testKey, incoplastBody)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d", rec.Code)
	}
	if pub.calls != 3 {
		t.Fatalf("fan-out must publish once per flow (3), got %d", pub.calls)
	}
	got := map[string]bool{}
	for _, b := range pub.bodies {
		got[sourceTypeOf(t, b)] = true
		if !strings.Contains(string(b), "incoplast-nr") {
			t.Fatalf("each fan-out copy must preserve the payload, got %s", b)
		}
	}
	for _, want := range []string{"", "go", "refactored"} {
		if !got[want] {
			t.Fatalf("missing fan-out copy for source_type %q (saw %v)", want, got)
		}
	}
}

func TestIngest_Fanout_PublishFailsMidway_503(t *testing.T) {
	// A broker failure on any copy → 503 so the tee retries the whole message.
	pub := &fakePublisher{healthy: true, err: context.DeadlineExceeded}
	h := New(Deps{
		APIKey:            testKey,
		MaxBodyBytes:      1 << 20,
		ScopeGroup:        "INCOPLAST",
		FanoutSourceTypes: []string{"", "go", "refactored"},
		Publisher:         pub,
		Metrics:           metrics.New(),
		Logger:            discardLogger(),
	})
	rec := do(t, h, testKey, incoplastBody)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503 when a fan-out copy fails, got %d", rec.Code)
	}
	if pub.calls != 1 {
		t.Fatalf("must stop at the first failed copy, got %d calls", pub.calls)
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
