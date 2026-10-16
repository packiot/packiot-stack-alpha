package adapter

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// openAPIExempt are ops routes deliberately NOT described in openapi.json.
var openAPIExempt = map[string]bool{"/healthz": true, "/health": true, "/metrics": true, "/openapi.json": true}

// recordingMux captures every pattern registerRoutes registers.
type recordingMux struct{ patterns []string }

func (m *recordingMux) Handle(pattern string, _ http.Handler) {
	m.patterns = append(m.patterns, pattern)
}

// splitPattern splits a Go 1.22 ServeMux pattern into (method, path). A
// method-less pattern returns method "".
func splitPattern(p string) (string, string) {
	if i := strings.IndexByte(p, ' '); i >= 0 {
		return p[:i], strings.TrimSpace(p[i+1:])
	}
	return "", p
}

// specOperations parses the embedded spec into path → set of upper-case methods.
func specOperations(t *testing.T) map[string]map[string]bool {
	t.Helper()
	var doc struct {
		OpenAPI string                                `json:"openapi"`
		Paths   map[string]map[string]json.RawMessage `json:"paths"`
	}
	if err := json.Unmarshal(openAPISpec, &doc); err != nil {
		t.Fatalf("openapi.json is not valid JSON: %v", err)
	}
	if !strings.HasPrefix(doc.OpenAPI, "3.1") {
		t.Fatalf("openapi = %q, want 3.1.x", doc.OpenAPI)
	}
	methods := map[string]bool{"get": true, "put": true, "post": true, "delete": true, "options": true, "head": true, "patch": true, "trace": true}
	ops := make(map[string]map[string]bool, len(doc.Paths))
	for path, item := range doc.Paths {
		ops[path] = map[string]bool{}
		for k := range item {
			if methods[k] {
				ops[path][strings.ToUpper(k)] = true
			}
		}
	}
	return ops
}

// TestOpenAPISpecMatchesRoutes fails on drift in either direction: a route
// registered on the mux but missing from openapi.json, or a documented
// path/method the mux does not serve.
func TestOpenAPISpecMatchesRoutes(t *testing.T) {
	rec := &recordingMux{}
	(&Server{}).registerRoutes(rec)
	spec := specOperations(t)

	registered := map[string]bool{}
	servesSpec := false
	for _, p := range rec.patterns {
		method, path := splitPattern(p)
		if path == "/openapi.json" && (method == "" || method == http.MethodGet) {
			servesSpec = true
		}
		if openAPIExempt[path] {
			continue
		}
		registered[path] = true
		ops, ok := spec[path]
		switch {
		case !ok || len(ops) == 0:
			t.Errorf("route %q is registered but not described in openapi.json", p)
		case method != "" && (!ops[method] || len(ops) != 1):
			t.Errorf("route %q: openapi.json documents methods %v for %s", p, ops, path)
		}
	}
	for path := range spec {
		if !registered[path] {
			t.Errorf("openapi.json documents %q but no such route is registered", path)
		}
	}
	if !servesSpec {
		t.Error("GET /openapi.json is not registered")
	}
}

func TestOpenAPIHandlerServesSpec(t *testing.T) {
	mux := http.NewServeMux()
	(&Server{}).registerRoutes(mux)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/openapi.json", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /openapi.json = %d, want 200", rr.Code)
	}
	if ct := rr.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	if !json.Valid(rr.Body.Bytes()) {
		t.Error("GET /openapi.json body is not valid JSON")
	}
}
