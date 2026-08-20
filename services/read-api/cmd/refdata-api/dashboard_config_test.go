package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// ── F2 (ADR-0029 §D2): the /v1/dashboard-config route tenancy + envelope gate ──
//
// The route is a bespoke query.go handler (like /v1/screen-config), so — as with
// that route — its tenant fence lives in a hand-written SQL const rather than a
// parseSQL-walked registry. These tests pin the two properties that keep it
// tenant-safe and contract-stable:
//   1. the resolve SQL fences BOTH composed relations to the injected tenant ($1);
//   2. the route is classified routeTenantScoped and is NOT auth-exempt;
// plus the not_found / invalid / ok envelope policy (DB-free, via the pure helper).

// TestDashboardConfigSQLFencesTenant proves the isolation invariant structurally:
// every relation the resolve query reads must be scoped by id_enterprise = $1, and
// $1 must be the ONLY tenant axis (the client cannot name a tenant). This is the
// bespoke-handler analogue of TestEveryDatasetIsTenantScoped's `$1` check.
func TestDashboardConfigSQLFencesTenant(t *testing.T) {
	sql := dashboardConfigResolveSQL
	// Both the baseline (dashboard_config) and the override (user_screen_config)
	// CTEs must carry the tenant fence — a missing fence on EITHER leaks configs
	// across tenants.
	if strings.Count(sql, "id_enterprise = $1") < 2 {
		t.Errorf("resolve SQL must fence BOTH composed relations with id_enterprise = $1:\n%s", sql)
	}
	for _, rel := range []string{"dashboard_config", "user_screen_config"} {
		if !strings.Contains(sql, rel) {
			t.Errorf("resolve SQL must read %q:\n%s", rel, sql)
		}
	}
	// The user axis is a WITHIN-tenant filter ($3), never a tenant axis. There
	// must be no $4 (the query binds exactly tenant/$1, dashboard_id/$2, user/$3).
	if strings.Contains(sql, "$4") {
		t.Errorf("resolve SQL binds an unexpected 4th parameter — only $1..$3 are expected:\n%s", sql)
	}
}

// TestDashboardConfigRouteIsTenantScopedAndAuthed pins the route's manifest class:
// routeTenantScoped (behind auth, tenant from the key) and NOT in the auth-exempt
// set. A future edit that drops the fence class or exempts it fails here.
func TestDashboardConfigRouteIsTenantScopedAndAuthed(t *testing.T) {
	const path = "/v1/dashboard-config"
	var found bool
	for _, rt := range routeManifest() {
		if rt.path == path {
			found = true
			if rt.class != routeTenantScoped {
				t.Errorf("route %q classified %d, want routeTenantScoped(%d)", path, rt.class, routeTenantScoped)
			}
		}
	}
	if !found {
		t.Fatalf("route %q is not in the manifest — the isolation gate cannot vet it", path)
	}
	if authExemptSet()[path] {
		t.Errorf("route %q is auth-exempt — every /v1 read must resolve the tenant from the credential", path)
	}
}

// TestResolveDashboardConfigRespEnvelope pins the wire contract the front4
// useDashboardConfig consumes across all three outcomes.
func TestResolveDashboardConfigRespEnvelope(t *testing.T) {
	// not_found: no baseline row (cross-tenant "disjoint/none").
	if r := resolveDashboardConfigResp(nil, 0, false); r.Status != "not_found" || r.Config != nil || r.Version != nil {
		t.Errorf("not_found: got %+v", r)
	}

	// invalid: a row exists but the stored config is not a JSON object.
	for _, bad := range []string{`[]`, `"x"`, `42`, `not-json`} {
		r := resolveDashboardConfigResp([]byte(bad), 1, true)
		if r.Status != "invalid" || len(r.Issues) == 0 {
			t.Errorf("invalid(%q): got %+v", bad, r)
		}
	}

	// ok: an object config → status ok, config passed through verbatim, version set.
	cfg := []byte(`{"schemaVersion":1,"id":"overview-standard","title":"","widgets":[]}`)
	r := resolveDashboardConfigResp(cfg, 3, true)
	if r.Status != "ok" || r.Version == nil || *r.Version != 3 {
		t.Fatalf("ok: got %+v", r)
	}
	// config must survive as a JSON object (round-trips to a map).
	var m map[string]any
	if err := json.Unmarshal(r.Config, &m); err != nil || m["id"] != "overview-standard" {
		t.Errorf("ok: config not passed through as an object: %s (%v)", r.Config, err)
	}
	// The whole envelope must marshal with the documented keys.
	b, _ := json.Marshal(r)
	if !strings.Contains(string(b), `"status":"ok"`) || !strings.Contains(string(b), `"version":3`) {
		t.Errorf("ok: envelope marshaled unexpectedly: %s", b)
	}
}
