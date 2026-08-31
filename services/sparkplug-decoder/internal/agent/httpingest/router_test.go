package httpingest

import (
	"io"
	"log/slog"
	"net/http"
	"testing"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

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
