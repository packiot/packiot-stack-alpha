// internal_test.go — ADR-0046 #19a resolver: the fail-closed auth + input
// validation paths that run BEFORE any DB touch, so they need no pool (the
// handler returns on the credential/validation guards before pool.QueryRow).
// The DB-backed 200/404 paths are covered by the edge-transformer resolver's
// integration against a live refdata (out of unit-test scope here).
package main

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func testResolveLogger() *slog.Logger { return slog.New(slog.NewTextHandler(os.Stderr, nil)) }

// TestResolveDeviceHandlerFailClosed pins the guards that must reject BEFORE the
// (nil) pool is ever dereferenced: an unset key, a wrong key, a non-GET method,
// and missing/invalid query params. A nil pool is safe precisely because a
// correct guard returns first — a regression that lets a request through would
// nil-panic, which the test would surface as a failure.
func TestResolveDeviceHandlerFailClosed(t *testing.T) {
	const goodKey = "s3cr3t-internal"

	cases := []struct {
		name       string
		configured string // INTERNAL_API_KEY the handler was built with
		method     string
		header     string // X-Internal-Key sent
		query      string
		wantStatus int
	}{
		// Key unset ⇒ endpoint inert: even an empty header must NOT match.
		{"key_unset_denies", "", http.MethodGet, "", "?enterprise=1&device_key=CPACK-SC-LINHAS-L5", http.StatusUnauthorized},
		{"key_unset_denies_with_header", "", http.MethodGet, "anything", "?enterprise=1&device_key=CPACK-SC-LINHAS-L5", http.StatusUnauthorized},
		// Configured key, missing/mismatched header ⇒ 401.
		{"missing_header", goodKey, http.MethodGet, "", "?enterprise=1&device_key=CPACK-SC-LINHAS-L5", http.StatusUnauthorized},
		{"wrong_header", goodKey, http.MethodGet, "nope", "?enterprise=1&device_key=CPACK-SC-LINHAS-L5", http.StatusUnauthorized},
		// Authed but malformed input ⇒ 400 (still no DB touch). NB: a MISSING
		// enterprise is NOT malformed — it is the ADR-0046 resolve-by-device_key
		// path (enterprise optional; device_key globally unique), which reaches
		// the DB, so it is exercised in the DB-backed resolution test, not here.
		{"nonnumeric_enterprise", goodKey, http.MethodGet, goodKey, "?enterprise=abc&device_key=CPACK-SC-LINHAS-L5", http.StatusBadRequest},
		{"nonpositive_enterprise", goodKey, http.MethodGet, goodKey, "?enterprise=0&device_key=CPACK-SC-LINHAS-L5", http.StatusBadRequest},
		{"missing_device_key", goodKey, http.MethodGet, goodKey, "?enterprise=1", http.StatusBadRequest},
		// Wrong method ⇒ 405, even with a valid key.
		{"post_rejected", goodKey, http.MethodPost, goodKey, "?enterprise=1&device_key=CPACK-SC-LINHAS-L5", http.StatusMethodNotAllowed},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// nil pool: a correct guard returns before QueryRow.
			h := resolveDeviceHandler(nil, tc.configured, testResolveLogger())
			req := httptest.NewRequest(tc.method, "/internal/resolve-device"+tc.query, nil)
			if tc.header != "" {
				req.Header.Set("X-Internal-Key", tc.header)
			}
			rec := httptest.NewRecorder()
			h(rec, req)
			if rec.Code != tc.wantStatus {
				t.Errorf("status = %d, want %d (body: %s)", rec.Code, tc.wantStatus, rec.Body.String())
			}
		})
	}
}

// TestInternalRouteIsClassifiedAndExempt is the wiring guard: the resolver route
// must be in the manifest as routeInternal AND auth-exempt (it self-auths). This
// is what lets the tenant middleware pass it through to the self-auth handler.
func TestInternalRouteIsClassifiedAndExempt(t *testing.T) {
	const path = "/internal/resolve-device"
	var class routeClass = -1
	for _, rt := range routeManifest() {
		if rt.path == path {
			class = rt.class
		}
	}
	if class != routeInternal {
		t.Fatalf("%s classified %d, want routeInternal (%d)", path, class, routeInternal)
	}
	if !authExemptSet()[path] {
		t.Errorf("%s must be auth-exempt (it self-authenticates via X-Internal-Key)", path)
	}
}
