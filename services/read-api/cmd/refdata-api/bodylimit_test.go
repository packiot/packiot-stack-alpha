package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Bodies over 64 KB are 413 {"error":"payload too large"} on every read-api
// JSON POST/PUT route. Before, io.LimitReader truncated them at 64 KB and the
// cut-off JSON failed as 400 "bad request body". All three paths reject before
// touching the DB, so a nil pool is safe.
func TestOversizedBodyIs413(t *testing.T) {
	mux := http.NewServeMux()
	registerQueryAPI(mux, nil, nil)
	registerHistorianAPI(mux, nil, nil)
	h := authMiddleware(map[string]int{"op-key": 9}, infraExemptSet(), nil, nil, mux)

	big := `{"dataset":"` + strings.Repeat("a", maxRequestBody) + `"}`
	for _, tc := range []struct{ method, path string }{
		{"POST", "/v1/query"},
		{"PUT", "/v1/screen-config?user=1&screen=mc"},
		{"POST", "/v1/historian/production-series"},
	} {
		req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(big))
		req.Header.Set("X-Api-Key", "op-key")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusRequestEntityTooLarge {
			t.Errorf("%s %s: code=%d body=%q; want 413", tc.method, tc.path, rr.Code, rr.Body.String())
		}
		if got := strings.TrimSpace(rr.Body.String()); got != `{"error":"payload too large"}` {
			t.Errorf("%s %s: body=%q; want payload too large", tc.method, tc.path, got)
		}
	}

	// At the cap is still read in full (then judged on content, not size).
	req := httptest.NewRequest("POST", "/v1/query", strings.NewReader(`{"dataset":"no-such"}`))
	req.Header.Set("X-Api-Key", "op-key")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("small body: code=%d; want 400 (unknown dataset)", rr.Code)
	}
}
