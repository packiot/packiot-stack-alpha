package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// closedPool returns a pool whose every query fails immediately with a
// non-ErrNoRows error — a DB outage without needing a database.
func closedPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), "postgres://u:p@127.0.0.1:1/x?sslmode=disable")
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	pool.Close()
	return pool
}

func screenConfigHandler(t *testing.T) http.Handler {
	mux := http.NewServeMux()
	registerQueryAPI(mux, closedPool(t), nil)
	return authMiddleware(map[string]int{"op-key": 9}, infraExemptSet(), nil, nil, mux)
}

// A DB error on GET must be a 500 with the standard error body, never the
// 200 `{}` that means "no layout saved" (the SPA would render, then save
// over, an empty layout during any outage).
func TestScreenConfigGetDBErrorIs500(t *testing.T) {
	req := httptest.NewRequest("GET", "/v1/screen-config?user=1&screen=mc", nil)
	req.Header.Set("X-Api-Key", "op-key")
	rr := httptest.NewRecorder()
	screenConfigHandler(t).ServeHTTP(rr, req)
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("GET with DB down: code=%d body=%q; want 500", rr.Code, rr.Body.String())
	}
	if got := strings.TrimSpace(rr.Body.String()); got != `{"error":"query failed"}` {
		t.Fatalf("GET with DB down: body=%q; want the standard query-failed body", got)
	}
}

func TestScreenConfigPutDBErrorIs500(t *testing.T) {
	req := httptest.NewRequest("PUT", "/v1/screen-config?user=1&screen=mc", strings.NewReader(`{"a":1}`))
	req.Header.Set("X-Api-Key", "op-key")
	rr := httptest.NewRecorder()
	screenConfigHandler(t).ServeHTTP(rr, req)
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("PUT with DB down: code=%d body=%q; want 500", rr.Code, rr.Body.String())
	}
}
