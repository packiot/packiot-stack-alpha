package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// mount registers the historian endpoint with a nil gateway pool (the disabled
// posture) and returns a mux to exercise the guard paths without a real gateway.
func mountHistorian() *http.ServeMux {
	mux := http.NewServeMux()
	registerHistorianAPI(mux, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return mux
}

func doHist(t *testing.T, mux *http.ServeMux, method, body string, withAuth bool) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, "/v1/historian/production-series", strings.NewReader(body))
	if withAuth {
		req = req.WithContext(withCustomerID(req.Context(), 3))
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func TestHistorian_MethodGuard(t *testing.T) {
	if got := doHist(t, mountHistorian(), http.MethodGet, "", true).Code; got != http.StatusMethodNotAllowed {
		t.Errorf("GET → %d, want 405", got)
	}
}

func TestHistorian_RequiresTenant(t *testing.T) {
	// No customer id in context (unauthenticated) → 401, BEFORE any pool use.
	if got := doHist(t, mountHistorian(), http.MethodPost,
		`{"from":"2024-01-01T00:00:00Z","to":"2024-02-01T00:00:00Z"}`, false).Code; got != http.StatusUnauthorized {
		t.Errorf("no tenant → %d, want 401", got)
	}
}

func TestHistorian_NilPoolIs503(t *testing.T) {
	// Authenticated + valid body, but the gateway is not configured (nil pool):
	// 503, never a panic. This is the nil-safe disabled posture.
	rec := doHist(t, mountHistorian(), http.MethodPost,
		`{"from":"2024-01-01T00:00:00Z","to":"2024-02-01T00:00:00Z"}`, true)
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("nil histPool → %d, want 503", rec.Code)
	}
}

func TestHistorian_WindowGuards(t *testing.T) {
	mux := mountHistorian()
	// The window guard must run BEFORE the nil-pool 503 so a malformed window is a
	// clean 400 regardless of gateway state. (from >= to)
	if got := doHist(t, mux, http.MethodPost,
		`{"from":"2024-02-01T00:00:00Z","to":"2024-01-01T00:00:00Z"}`, true).Code; got != http.StatusBadRequest {
		t.Errorf("from>=to → %d, want 400", got)
	}
	// window exceeding the historian budget (~5y)
	if got := doHist(t, mux, http.MethodPost,
		`{"from":"2010-01-01T00:00:00Z","to":"2024-01-01T00:00:00Z"}`, true).Code; got != http.StatusBadRequest {
		t.Errorf("oversized window → %d, want 400", got)
	}
}

// TestHistorianSQLShape locks the tenant fence + prune + optional-equipment
// contract so a refactor can't silently drop the isolation or the pruning.
func TestHistorianSQLShape(t *testing.T) {
	for _, m := range []string{
		"FROM ev_all",                      // the VIEW (mixed hot+cold); NOT the ev_between function
		"id_enterprise = $1",               // tenant fence on the SERVER-resolved cid
		"ts_value >= $2 AND ts_value < $3", // exact window bound
		"\n     %s\n",                      // optional equipment filter is an INLINE list (not a param)
		"year >  $4 OR (year = $4 AND month >= $5)", // cold-partition prune (lower)
		"date_trunc('day', ts_value)",      // daily aggregate (bounds row count)
	} {
		if !strings.Contains(histProductionSeriesSQL, m) {
			t.Errorf("historian SQL lost %q", m)
		}
	}
}
