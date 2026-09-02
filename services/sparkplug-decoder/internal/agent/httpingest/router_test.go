package httpingest

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// postGroupHeader posts a body with an optional X-Ingest-Group header (empty ⇒
// header omitted). Mirrors post() but exercises the FIX-3 header routing fallback.
func postGroupHeader(t *testing.T, h http.Handler, key, headerGroup, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/tags", strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-Ingest-Key", key)
	}
	if headerGroup != "" {
		req.Header.Set("X-Ingest-Group", headerGroup)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// noGroupBody is a well-formed envelope with NO top-level group — the legacy-tee
// shape the X-Ingest-Group header exists to route.
const noGroupBody = `{"scan_ts":1,"tags":[{"metric":"/Status/MachSpeed","value":118.4}]}`

// TestRouter_HeaderGroupFallback: a body with no group but an X-Ingest-Group
// header routes to that tenant (202) — the per-tenant nginx front-door injecting
// the group for a legacy tee that sends none.
func TestRouter_HeaderGroupFallback(t *testing.T) {
	a, b := &captureSink{}, &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn, "INCOPLAST": b.fn})

	if rec := postGroupHeader(t, h, testKey, "CPACK", noGroupBody); rec.Code != http.StatusAccepted {
		t.Fatalf("header-routed: status got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 1 || b.count() != 0 {
		t.Fatalf("header X-Ingest-Group must route to CPACK only: A=%d (want 1), B=%d (want 0)", a.count(), b.count())
	}
}

// TestRouter_HeaderGroupCaseInsensitive: the header key is normalized (upper +
// trim) exactly like a body group.
func TestRouter_HeaderGroupCaseInsensitive(t *testing.T) {
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	if rec := postGroupHeader(t, h, testKey, "  cpack ", noGroupBody); rec.Code != http.StatusAccepted {
		t.Fatalf("status got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 1 {
		t.Fatalf("case/whitespace-normalized header route: A=%d want 1", a.count())
	}
}

// TestRouter_HeaderGroupUnknown403: a header naming an unknown tenant is still a
// 403 (the header is only a routing KEY, not a bypass).
func TestRouter_HeaderGroupUnknown403(t *testing.T) {
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	rec := postGroupHeader(t, h, testKey, "NOTATENANT", noGroupBody)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status got %d want 403 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 0 {
		t.Fatalf("unknown header group must not reach any sink; A=%d", a.count())
	}
}

// TestRouter_NoGroupNoHeader403: neither a body group nor the header ⇒ 403,
// unchanged (the header is a fallback, not a new way to skip routing).
func TestRouter_NoGroupNoHeader403(t *testing.T) {
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	rec := postGroupHeader(t, h, testKey, "", noGroupBody)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status got %d want 403 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 0 {
		t.Fatalf("no group and no header must reach no sink; A=%d", a.count())
	}
}

// TestRouter_BodyGroupWinsOverHeader: when BOTH are present the body group wins
// and the header is ignored — the precedence contract (body > header > 403).
func TestRouter_BodyGroupWinsOverHeader(t *testing.T) {
	a, b := &captureSink{}, &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn, "INCOPLAST": b.fn})
	// Body says CPACK, header says INCOPLAST → must land in CPACK.
	if rec := postGroupHeader(t, h, testKey, "INCOPLAST", bodyForGroup("CPACK")); rec.Code != http.StatusAccepted {
		t.Fatalf("status got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 2 || b.count() != 0 {
		t.Fatalf("body group must win over header: CPACK=%d (want 2), INCOPLAST=%d (want 0)", a.count(), b.count())
	}
}

// TestSingleMode_IgnoresHeaderGroup: in SINGLE mode the X-Ingest-Group header is
// ignored — an absent body group is accepted regardless (frozen behavior), and a
// header naming a foreign tenant does NOT cause a 403.
func TestSingleMode_IgnoresHeaderGroup(t *testing.T) {
	sink := &captureSink{}
	h := newTestServer(t, "CPACK", sink.fn) // single mode, scope=CPACK
	// Body has no group; header names a different tenant. Single mode ignores the
	// header and accepts the absent-group body (the tag_map drops foreign metrics).
	if rec := postGroupHeader(t, h, testKey, "INCOPLAST", noGroupBody); rec.Code != http.StatusAccepted {
		t.Fatalf("single mode must ignore X-Ingest-Group and accept absent-group body: got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if sink.count() != 1 {
		t.Fatalf("single-mode sink should see the tag: got %d want 1", sink.count())
	}
}

// newRouterServer builds a multi-tenant router over the given per-group sinks.
func newRouterServer(t *testing.T, routes map[string]Sink) http.Handler {
	t.Helper()
	outcomes := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "test_router_total"}, []string{"outcome"})
	srv := NewRouter(Config{APIKey: testKey}, routes, outcomes, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return srv.Handler()
}

// bodyForGroup stamps a two-tag envelope with the given top-level group. The
// suffix "/Status/MachSpeed" is intentionally SHARED across tenants — the point
// of the router is that the same suffix lands in a different tenant's pipeline
// depending only on the envelope group.
func bodyForGroup(group string) string {
	return `{"group":"` + group + `","scan_ts":1,"tags":[` +
		`{"metric":"/Status/MachSpeed","value":118.4},` +
		`{"metric":"/Status/StateCurrent","value":6,"long":true}` +
		`]}`
}

func TestRouter_RoutesByGroup(t *testing.T) {
	a, b := &captureSink{}, &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn, "INCOPLAST": b.fn})

	// Group A → only A's sink sees the tags.
	if rec := post(t, h, testKey, bodyForGroup("CPACK")); rec.Code != http.StatusAccepted {
		t.Fatalf("CPACK: status got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 2 || b.count() != 0 {
		t.Fatalf("after CPACK post: A=%d (want 2), B=%d (want 0)", a.count(), b.count())
	}

	// Group B → only B's sink. Proves the two tenants never share a pipeline
	// even though the envelope suffixes are identical.
	if rec := post(t, h, testKey, bodyForGroup("INCOPLAST")); rec.Code != http.StatusAccepted {
		t.Fatalf("INCOPLAST: status got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 2 || b.count() != 2 {
		t.Fatalf("after INCOPLAST post: A=%d (want 2), B=%d (want 2)", a.count(), b.count())
	}
}

func TestRouter_GroupMatchIsCaseInsensitive(t *testing.T) {
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	// lowercase group in the envelope must still route to the upper-keyed route.
	if rec := post(t, h, testKey, bodyForGroup("cpack")); rec.Code != http.StatusAccepted {
		t.Fatalf("status got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 2 {
		t.Fatalf("case-insensitive route: A=%d want 2", a.count())
	}
}

func TestRouter_UnknownGroup403(t *testing.T) {
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	rec := post(t, h, testKey, bodyForGroup("NOTATENANT"))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status got %d want 403 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 0 {
		t.Fatalf("unknown-group request must not reach any sink; A=%d", a.count())
	}
}

func TestRouter_MissingGroup403(t *testing.T) {
	// In multi-tenant mode a body with no group has no route to take — 403,
	// never a silent drop into some default pipeline. (Contrast single-file
	// mode, where an absent group is accepted; see TestIngest_AbsentGroupAccepted.)
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	body := `{"scan_ts":1,"tags":[{"metric":"/Status/MachSpeed","value":1}]}`
	rec := post(t, h, testKey, body)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status got %d want 403 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 0 {
		t.Fatalf("missing-group request must not reach any sink; A=%d", a.count())
	}
}

func TestRouter_BadKey401(t *testing.T) {
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	rec := post(t, h, "wrong-key", bodyForGroup("CPACK"))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status got %d want 401", rec.Code)
	}
	if a.count() != 0 {
		t.Fatalf("rejected request must not reach the sink; A=%d", a.count())
	}
}

func TestNewRouter_PanicsWithoutRoutes(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("NewRouter must panic with no routes")
		}
	}()
	NewRouter(Config{APIKey: testKey}, map[string]Sink{}, nil, slog.Default())
}

func TestNewRouter_PanicsOnNilSink(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("NewRouter must panic on a nil route sink")
		}
	}()
	NewRouter(Config{APIKey: testKey}, map[string]Sink{"CPACK": nil}, nil, slog.Default())
}

func TestNewRouter_PanicsWithoutKey(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("NewRouter must panic when APIKey is empty")
		}
	}()
	NewRouter(Config{APIKey: ""}, map[string]Sink{"CPACK": func([]rawtag.RawTag) (int, int) { return 0, 0 }}, nil, slog.Default())
}

// TestRouter_TrimsGroupWhitespace confirms the route key normalization also
// trims surrounding whitespace (a lenient tee might pad the group).
func TestRouter_TrimsGroupWhitespace(t *testing.T) {
	a := &captureSink{}
	h := newRouterServer(t, map[string]Sink{"CPACK": a.fn})
	body := `{"group":"  CPACK  ","scan_ts":1,"tags":[{"metric":"/Status/MachSpeed","value":1}]}`
	rec := post(t, h, testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status got %d want 202 (body=%s)", rec.Code, rec.Body.String())
	}
	if a.count() != 1 {
		t.Fatalf("whitespace-padded group route: A=%d want 1", a.count())
	}
}
