package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
)

// The OpenAPI drift gate. registerRoutes is the one place routes are mounted
// (routes.go); this test mounts the whole surface onto a recorder and demands a
// 1:1 match with the spec's paths. Adding a route without documenting it, or
// deleting one and leaving its spec entry behind, fails here.

// specExempt are mounted but deliberately absent from the spec (ops probes +
// the spec itself).
var specExempt = map[string]bool{"/healthz": true, "/health": true, "/metrics": true, "/openapi.json": true}

func mountedPatterns(t *testing.T) []string {
	t.Helper()
	rec := &patternRecorder{mux: http.NewServeMux()}
	registerRoutes(rec, routeDeps{logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	return rec.patterns
}

func buildSpecT(t *testing.T) map[string]any {
	t.Helper()
	spec, err := buildOpenAPISpec()
	if err != nil {
		t.Fatalf("buildOpenAPISpec: %v", err)
	}
	return spec
}

func TestOpenAPICoversEveryMountedRoute(t *testing.T) {
	patterns := mountedPatterns(t)
	paths := buildSpecT(t)["paths"].(map[string]any)

	mounted := map[string]bool{}
	for _, p := range patterns {
		mounted[p] = true
		if specExempt[p] {
			continue
		}
		if _, ok := paths[p]; !ok {
			t.Errorf("route %q is mounted but missing from the OpenAPI spec (openapi.go)", p)
		}
	}
	for p := range paths {
		if specExempt[p] {
			t.Errorf("spec documents %q, which is an ops route kept out of the spec", p)
		}
		if !mounted[p] {
			t.Errorf("spec documents %q but no such route is mounted (stale entry?)", p)
		}
	}
	if !mounted["/openapi.json"] {
		t.Error("/openapi.json is not mounted")
	}
	// Sanity: the table sizes the spec is generated from.
	want := len(endpoints) + len(externalShims) + len(queryAPIRoutes) + len(internalRoutes) + 2 // + 2 historian
	if len(paths) != want {
		got := make([]string, 0, len(paths))
		for p := range paths {
			got = append(got, p)
		}
		sort.Strings(got)
		t.Errorf("spec has %d paths, want %d: %v", len(paths), want, got)
	}
}

// The hand-written enrichment maps must not outlive their table rows.
func TestOpenAPIEnrichmentHasNoOrphans(t *testing.T) {
	eps := map[string]bool{}
	for _, ep := range endpoints {
		eps[ep.path] = true
	}
	for p := range endpointSummaries {
		if !eps[p] {
			t.Errorf("endpointSummaries has %q, which is not in the endpoints table", p)
		}
	}
	shims := map[string]bool{}
	for _, sh := range externalShims {
		shims[sh.path] = true
	}
	for p := range shimDocs {
		if !shims[p] {
			t.Errorf("shimDocs has %q, which is not in the externalShims registry", p)
		}
	}
}

// Security must mirror the auth wiring: middleware routes take X-Api-Key or a
// Bearer, auth-exempt routes must NOT claim the middleware schemes, and every
// referenced scheme is declared.
func TestOpenAPISecurityMatchesAuthClasses(t *testing.T) {
	spec := buildSpecT(t)
	schemes := spec["components"].(map[string]any)["securitySchemes"].(map[string]any)
	exempt := authExemptSet()
	opIDs := map[string]string{}
	for path, item := range spec["paths"].(map[string]any) {
		for method, raw := range item.(map[string]any) {
			op := raw.(map[string]any)
			id, _ := op["operationId"].(string)
			if prev, dup := opIDs[id]; id == "" || dup {
				t.Errorf("%s %s: operationId %q missing or already used by %s", method, path, id, prev)
			}
			opIDs[id] = method + " " + path
			sec, ok := op["security"].([]any)
			if !ok || len(sec) == 0 {
				t.Errorf("%s %s: no security requirement", method, path)
				continue
			}
			names := map[string]bool{}
			for _, req := range sec {
				for name := range req.(map[string]any) {
					if _, ok := schemes[name]; !ok {
						t.Errorf("%s %s: undeclared security scheme %q", method, path, name)
					}
					names[name] = true
				}
			}
			isExempt := exemptMatch(exempt, path)
			if isExempt && (names[secAPIKey] || names[secBearer]) {
				t.Errorf("%s %s is auth-exempt (self-authenticating) but claims the middleware schemes", method, path)
			}
			if !isExempt && !(names[secAPIKey] && names[secBearer] && len(names) == 2) {
				t.Errorf("%s %s is behind the auth middleware; security must be exactly ApiKey | CognitoBearer, got %v", method, path, names)
			}
		}
	}
}

// The served document is valid JSON, declares 3.1, and needs no credential.
func TestOpenAPIServedWithoutAuth(t *testing.T) {
	mux := http.NewServeMux()
	registerRoutes(mux, routeDeps{logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	h := authMiddleware(map[string]int{"k": 1}, authExemptSet(), nil, nil, mux)

	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/openapi.json", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /openapi.json without credentials = %d, want 200", rr.Code)
	}
	if ct := rr.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type = %q", ct)
	}
	var doc map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &doc); err != nil {
		t.Fatalf("body is not JSON: %v", err)
	}
	if doc["openapi"] != "3.1.0" {
		t.Errorf("openapi = %v, want 3.1.0", doc["openapi"])
	}

	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodPost, "/openapi.json", nil))
	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /openapi.json = %d, want 405", rr.Code)
	}
}
