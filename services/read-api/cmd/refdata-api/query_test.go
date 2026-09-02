package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCompileEnforcesCatalogAndTenancy(t *testing.T) {
	base := queryReq{Metrics: []string{"net_production"}, Dimensions: []string{"equipment"},
		Grain: "1hour", From: time.Now().Add(-24 * time.Hour), To: time.Now()}
	sql, args, err := compile(base, 3)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "FROM agg_equipment_values_1hour") ||
		!strings.Contains(sql, "id_enterprise = $1") || args[0] != 3 {
		t.Errorf("tenancy/grain not enforced: %s %v", sql, args)
	}
	if !strings.Contains(sql, "LIMIT 10000") {
		t.Error("row limit missing")
	}
	for _, bad := range []queryReq{
		{Metrics: []string{"pg_sleep"}, Grain: "1hour", From: base.From, To: base.To},
		{Metrics: []string{"net_production"}, Grain: "raw", From: base.From, To: base.To},
		{Metrics: []string{"net_production"}, Dimensions: []string{"x; DROP"}, Grain: "1hour", From: base.From, To: base.To},
		{Metrics: []string{"net_production"}, Grain: "1min", From: time.Now().Add(-30 * 24 * time.Hour), To: time.Now()}, // window > budget
	} {
		if _, _, err := compile(bad, 3); err == nil {
			t.Errorf("compile accepted invalid request: %+v", bad)
		}
	}
}

func TestParseAPIKeys(t *testing.T) {
	m := parseAPIKeys("a:3, b:2,broken,:9")
	if m["a"] != 3 || m["b"] != 2 || len(m) != 2 {
		t.Errorf("parseAPIKeys: %v", m)
	}
}

// TestQueryHandlerRoleDatasetViaXApiKeyIs403 is the end-to-end proof of the
// task #70 §3 decision: a role dataset requested over the X-Api-Key operator
// path (which resolves a tenant but NO user identity) is rejected with 403
// BEFORE any DB access — never an unscoped tenant-wide role list. A nil pool is
// safe here precisely because compileDataset fails closed before pool.Query.
// The operator's existing (non-role) datasets are unaffected: only the two
// per-user-role datasets carry the pUserRole axis.
func TestQueryHandlerRoleDatasetViaXApiKeyIs403(t *testing.T) {
	mux := http.NewServeMux()
	registerQueryAPI(mux, nil, nil) // 403 path returns before any pool use (nil cache ⇒ bypass)
	// Operator credential: a tenant, no Bearer path (nil resolver) → no user axis.
	handler := authMiddleware(map[string]int{"op-key": 9}, infraExemptSet(), nil, mux)

	for _, name := range []string{"entities-per-user-role", "menu-per-user-role"} {
		req := httptest.NewRequest("POST", "/v1/query",
			strings.NewReader(`{"dataset":"`+name+`"}`))
		req.Header.Set("X-Api-Key", "op-key")
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if rr.Code != http.StatusForbidden {
			t.Errorf("%s via X-Api-Key: code=%d body=%s; want 403 (dataset requires user context)",
				name, rr.Code, rr.Body.String())
		}
		if !strings.Contains(rr.Body.String(), "requires user context") {
			t.Errorf("%s: 403 body should explain the missing user context; got %s", name, rr.Body.String())
		}
	}

	// Sanity: an unknown dataset over the same path is a 400 (malformed), not a
	// 403 — the 403 is specifically the missing-user-context signal.
	req := httptest.NewRequest("POST", "/v1/query", strings.NewReader(`{"dataset":"no-such"}`))
	req.Header.Set("X-Api-Key", "op-key")
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("unknown dataset: code=%d; want 400", rr.Code)
	}
}
