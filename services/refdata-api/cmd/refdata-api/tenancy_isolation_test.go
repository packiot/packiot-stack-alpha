package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Tenancy isolation gate (ADR-0021 M1 §2, Level-1 as a merge rule).
//
// The composable read surface is multi-tenant: customer_id is injected
// server-side from the API key as $1 and is NEVER client-supplied. The
// structural invariant that guarantees no cross-tenant bleed is:
//
//	every dataset's FIRST parameter is pEnterprise (bound to $1), and its
//	SQL actually uses $1 to scope to that tenant.
//
// A dataset added without that guard — a raw SELECT with no enterprise
// scope, or one whose first param is a client-supplied filter — would
// return another tenant's rows. This test fails such a dataset at CI,
// so isolation is a checked property, not a hope. It is deliberately
// DB-free: it proves the *contract* every dataset must honor.

func TestEveryDatasetIsTenantScoped(t *testing.T) {
	if len(datasets) == 0 {
		t.Fatal("no datasets registered — the isolation gate has nothing to guard")
	}
	for name, ds := range datasets {
		// 1. The tenancy guard must be the FIRST parameter, so it binds $1.
		if len(ds.params) == 0 || ds.params[0].kind != pEnterprise {
			t.Errorf("dataset %q: params[0] must be pEnterprise (customer_id from auth, $1); "+
				"a dataset whose first arg is client-supplied leaks across tenants", name)
			continue
		}
		// 2. pEnterprise must appear EXACTLY once — a second injected
		//    enterprise arg would desync the $-index of the rest.
		nEnt := 0
		for _, p := range ds.params {
			if p.kind == pEnterprise {
				nEnt++
			}
		}
		if nEnt != 1 {
			t.Errorf("dataset %q: expected exactly one pEnterprise param, got %d", name, nEnt)
		}
		// 3. The SQL must actually USE $1 — a dataset that takes the
		//    enterprise arg but never references it isn't scoped.
		if !strings.Contains(ds.sql, "$1") {
			t.Errorf("dataset %q: SQL never references $1 (the injected customer_id) — not tenant-scoped:\n%s",
				name, ds.sql)
		}
	}
}

// compileDataset must place the caller's customerID at $1 for every
// dataset, regardless of the request body — the client cannot move it.
func TestCompiledArgsPinCustomerIDAtDollarOne(t *testing.T) {
	const tenantA, tenantB = 3, 4
	for name, ds := range datasets {
		req := datasetReq{Dataset: name}
		if ds.windowed {
			// minimal valid window so compile doesn't reject on bounds
			req.Window = &dsWindow{From: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), To: time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)}
		}
		aSQL, aArgs, aErr := compileDataset(req, tenantA)
		bSQL, bArgs, bErr := compileDataset(req, tenantB)
		if aErr != nil || bErr != nil {
			// A dataset needing required client params can't be compiled
			// from an empty body — the structural test above already
			// guards those; skip the arg check here.
			continue
		}
		if len(aArgs) == 0 || aArgs[0] != tenantA || len(bArgs) == 0 || bArgs[0] != tenantB {
			t.Errorf("dataset %q: $1 must be the caller's customerID (got %v / %v for tenants %d/%d)",
				name, first(aArgs), first(bArgs), tenantA, tenantB)
		}
		// The compiled SQL must be identical across tenants — only the
		// bound arg differs. Divergent SQL would hint at customerID
		// leaking into the query text.
		if aSQL != bSQL {
			t.Errorf("dataset %q: compiled SQL differs between tenants — customerID must be a bound arg, not text", name)
		}
	}
}

func first(a []any) any {
	if len(a) == 0 {
		return nil
	}
	return a[0]
}

// ── ADR-0027 Surface-1: the gate now covers the ENTIRE mux ────────────────
//
// Before Surface-1 the isolation gate guarded only the `datasets` map
// (Generation B). The eleven Generation-A endpoints (main.go) and the query-
// API routes bypassed it — the #57 hole. These tests extend the checked
// property to every mux route: each is classified, every tenant-scoped route
// binds the server-derived customer_id as $1, and the auth middleware fails
// closed. A future route added without a class, or a re-homed endpoint that
// drops its $1 predicate, fails the build — #57 becomes non-regressable.

// TestEndpointTableIsTenantSafe is the Generation-A analogue of
// TestEveryDatasetIsTenantScoped: every fixed endpoint is either tenant-scoped
// (SQL binds $1) or an explicitly-enumerated global reference (language_packs).
func TestEndpointTableIsTenantSafe(t *testing.T) {
	if len(endpoints) == 0 {
		t.Fatal("no endpoints — the gate has nothing to guard")
	}
	globalRefs := 0
	for _, ep := range endpoints {
		switch ep.class {
		case routeTenantScoped:
			if !strings.Contains(ep.sql, "$1") {
				t.Errorf("endpoint %q: tenant-scoped but SQL never binds the customer_id $1:\n%s", ep.path, ep.sql)
			}
		case routeGlobalRef:
			globalRefs++
			// The only permitted global read is tenant-independent i18n.
			if !strings.Contains(ep.sql, "language_packs") {
				t.Errorf("endpoint %q: routeGlobalRef is reserved for tenant-independent reference data (language_packs); got:\n%s", ep.path, ep.sql)
			}
		case routeInfra:
			t.Errorf("endpoint %q: a data-serving endpoint may not be routeInfra", ep.path)
		}
		// The tenancy secret must never transit this API.
		if strings.Contains(ep.sql, "api_key") {
			t.Errorf("endpoint %q: SQL references api_key", ep.path)
		}
		// The client may no longer name a tenant: no ?enterprise= survives in
		// any re-homed SQL (it must come from $1, the key).
		if strings.Contains(ep.sql, "$enterprise") {
			t.Errorf("endpoint %q: SQL still references a client-supplied enterprise", ep.path)
		}
	}
	if globalRefs != 1 {
		t.Errorf("expected exactly one global-reference endpoint (language_packs), got %d", globalRefs)
	}
}

// TestRouteManifestCoversEveryRoute asserts the manifest — the single source
// of truth shared by the auth middleware and this gate — classifies every mux
// route, that /v1 reads are behind auth, and that only infra probes are exempt.
func TestRouteManifestCoversEveryRoute(t *testing.T) {
	seen := map[string]routeClass{}
	for _, rt := range routeManifest() {
		if prev, dup := seen[rt.path]; dup {
			t.Errorf("route %q listed twice in the manifest (classes %d and %d)", rt.path, prev, rt.class)
		}
		seen[rt.path] = rt.class
	}
	// The query-API + infra routes must be present and correctly classed — a
	// new /v1 route added without a class is a build failure here.
	want := map[string]routeClass{
		"/v1/query":         routeTenantScoped,
		"/v1/screen-config": routeTenantScoped,
		"/v1/catalog":       routeGlobalRef,
		"/healthz":          routeInfra,
		"/metrics":          routeInfra,
	}
	for path, class := range want {
		if got, ok := seen[path]; !ok {
			t.Errorf("route %q missing from the manifest", path)
		} else if got != class {
			t.Errorf("route %q classified %d, want %d", path, got, class)
		}
	}
	// Every endpoint must appear in the manifest with its declared class.
	for _, ep := range endpoints {
		if seen[ep.path] != ep.class {
			t.Errorf("endpoint %q missing/mis-classed in manifest (got %d, want %d)", ep.path, seen[ep.path], ep.class)
		}
	}
	// Invariant: every /v1 read resolves the tenant from the key (i.e. is NOT
	// auth-exempt); only infra probes are exempt.
	exempt := infraExemptSet()
	for path, class := range seen {
		if strings.HasPrefix(path, "/v1/") && exempt[path] {
			t.Errorf("route %q is a /v1 read but is auth-exempt — every read must resolve the tenant from the key", path)
		}
		if class == routeInfra && !exempt[path] {
			t.Errorf("infra route %q is not in the auth-exempt set", path)
		}
		if class != routeInfra && exempt[path] {
			t.Errorf("route %q is auth-exempt but not classified as infra", path)
		}
	}
}

// TestAuthMiddlewareFailsClosed proves the behavior, not just the wiring: no
// key and unknown key both 401 WITHOUT reaching the handler (no DB touch), a
// valid key injects the customer_id, and infra probes pass through.
func TestAuthMiddlewareFailsClosed(t *testing.T) {
	keys := map[string]int{"good-key": 7}
	exempt := infraExemptSet()
	var reached bool
	var gotCID int
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		gotCID, _ = customerIDFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	mw := authMiddleware(keys, exempt, nil, next) // nil bearer: X-Api-Key path only

	cases := []struct {
		name      string
		key       string
		setKey    bool
		path      string
		wantCode  int
		wantReach bool
		wantCID   int
	}{
		{"no-key on tenant route", "", false, "/v1/operator-po-list", http.StatusUnauthorized, false, 0},
		{"unknown-key", "nope", true, "/v1/operator-po-list", http.StatusUnauthorized, false, 0},
		{"valid-key injects cid", "good-key", true, "/v1/operator-po-list", http.StatusOK, true, 7},
		{"healthz exempt (no key)", "", false, "/healthz", http.StatusOK, true, 0},
		{"metrics exempt (no key)", "", false, "/metrics", http.StatusOK, true, 0},
	}
	for _, c := range cases {
		reached, gotCID = false, 0
		req := httptest.NewRequest("GET", c.path, nil)
		if c.setKey {
			req.Header.Set("X-Api-Key", c.key)
		}
		rr := httptest.NewRecorder()
		mw.ServeHTTP(rr, req)
		if rr.Code != c.wantCode || reached != c.wantReach || gotCID != c.wantCID {
			t.Errorf("%s: code=%d reached=%v cid=%d; want code=%d reached=%v cid=%d",
				c.name, rr.Code, reached, gotCID, c.wantCode, c.wantReach, c.wantCID)
		}
	}
}

// TestAuthMiddlewareEmptyKeysDeniesAll: an empty/malformed QUERY_API_KEYS
// yields an empty map ⇒ EVERY non-infra route 401s. Credential-source failure
// denies all access; it never falls through to "no filter".
func TestAuthMiddlewareEmptyKeysDeniesAll(t *testing.T) {
	mw := authMiddleware(map[string]int{}, infraExemptSet(), nil, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler reached with an empty keys map and nil bearer — must fail closed")
	}))
	req := httptest.NewRequest("GET", "/v1/query", nil)
	req.Header.Set("X-Api-Key", "anything")
	rr := httptest.NewRecorder()
	mw.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("empty keys: code=%d, want 401", rr.Code)
	}
}

// ── task #68: the Firebase-JWT tenant path, same rigor as X-Api-Key ────────
//
// These extend the isolation gate to the SECOND credential type. The property
// under test is identical to the key path: the tenant is derived SERVER-SIDE
// (here from the verified uid, never from anything the browser names) and
// injected as the context customer_id that makeHandler binds at $1. A bad or
// unknown token must fail closed to 401 without reaching a handler.

// fakeBearer builds a bearerResolver from a verified-uid→cid table, recording
// whether it was invoked (to prove X-Api-Key precedence short-circuits it).
type fakeBearer struct {
	table  map[string]int // token string → resolved customer_id
	called bool
}

func (f *fakeBearer) resolve(_ context.Context, token string) (int, error) {
	f.called = true
	cid, ok := f.table[token]
	if !ok {
		return 0, errUnknownUID
	}
	return cid, nil
}

// TestBearerPathResolvesTenantServerSide proves the JWT path binds the
// server-derived customer_id into context (→ $1), and fails closed on a bad or
// unknown token — the front4 SPA never supplies a tenant or a key.
func TestBearerPathResolvesTenantServerSide(t *testing.T) {
	fb := &fakeBearer{table: map[string]int{"tok-A": 11, "tok-B": 22}}
	var reached bool
	var gotCID int
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		gotCID, _ = customerIDFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	mw := authMiddleware(map[string]int{}, infraExemptSet(), fb.resolve, next)

	cases := []struct {
		name      string
		authz     string // Authorization header value ("" = unset)
		wantCode  int
		wantReach bool
		wantCID   int
	}{
		{"valid token A → tenant 11", "Bearer tok-A", http.StatusOK, true, 11},
		{"valid token B → tenant 22 (uid drives tenant)", "Bearer tok-B", http.StatusOK, true, 22},
		{"lowercase scheme accepted", "bearer tok-A", http.StatusOK, true, 11},
		{"unknown token (valid sig, no enterprise) → 401", "Bearer tok-unknown", http.StatusUnauthorized, false, 0},
		{"malformed Authorization → 401", "Basic zzz", http.StatusUnauthorized, false, 0},
		{"empty bearer → 401", "Bearer ", http.StatusUnauthorized, false, 0},
		{"no credential at all → 401", "", http.StatusUnauthorized, false, 0},
	}
	for _, c := range cases {
		reached, gotCID = false, 0
		req := httptest.NewRequest("GET", "/v1/operator-po-list", nil)
		if c.authz != "" {
			req.Header.Set("Authorization", c.authz)
		}
		rr := httptest.NewRecorder()
		mw.ServeHTTP(rr, req)
		if rr.Code != c.wantCode || reached != c.wantReach || gotCID != c.wantCID {
			t.Errorf("%s: code=%d reached=%v cid=%d; want code=%d reached=%v cid=%d",
				c.name, rr.Code, reached, gotCID, c.wantCode, c.wantReach, c.wantCID)
		}
	}
}

// TestBearerVerifyErrorFailsClosed: a token that fails verification
// (bad/expired/wrong-project — the resolver returns any error) → 401, no
// handler, no tenant. Uses a resolver that always errors, standing in for a
// failed VerifyIDToken.
func TestBearerVerifyErrorFailsClosed(t *testing.T) {
	badResolver := func(context.Context, string) (int, error) { return 0, errEmptySubject }
	mw := authMiddleware(map[string]int{}, infraExemptSet(), badResolver,
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			t.Error("handler reached with an unverifiable token — must fail closed")
		}))
	req := httptest.NewRequest("GET", "/v1/query", nil)
	req.Header.Set("Authorization", "Bearer forged.jwt.here")
	rr := httptest.NewRecorder()
	mw.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("unverifiable token: code=%d, want 401", rr.Code)
	}
}

// TestBearerDisabledWhenNilResolver: with the Bearer path unconfigured (nil
// resolver), a Bearer credential must 401 — never silently succeed.
func TestBearerDisabledWhenNilResolver(t *testing.T) {
	mw := authMiddleware(map[string]int{"k": 5}, infraExemptSet(), nil,
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			t.Error("handler reached with a Bearer token but nil resolver — must fail closed")
		}))
	req := httptest.NewRequest("GET", "/v1/query", nil)
	req.Header.Set("Authorization", "Bearer some-token")
	rr := httptest.NewRecorder()
	mw.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("nil bearer resolver: code=%d, want 401", rr.Code)
	}
}

// TestXApiKeyWinsOverBearer documents+enforces the precedence: a present
// X-Api-Key is authoritative. A VALID key resolves via the key and never
// consults the Bearer resolver; an INVALID key 401s WITHOUT falling through to
// Bearer (no cross-credential probing in one request).
func TestXApiKeyWinsOverBearer(t *testing.T) {
	fb := &fakeBearer{table: map[string]int{"tok-A": 99}}
	var gotCID int
	var reached bool
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		gotCID, _ = customerIDFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	mw := authMiddleware(map[string]int{"good": 7}, infraExemptSet(), fb.resolve, next)

	// (1) valid key + bearer both present → key wins, bearer NOT consulted.
	fb.called, reached, gotCID = false, false, 0
	req := httptest.NewRequest("GET", "/v1/operator-po-list", nil)
	req.Header.Set("X-Api-Key", "good")
	req.Header.Set("Authorization", "Bearer tok-A")
	rr := httptest.NewRecorder()
	mw.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK || gotCID != 7 || !reached {
		t.Errorf("valid key + bearer: code=%d cid=%d reached=%v; want 200 cid=7 reached=true", rr.Code, gotCID, reached)
	}
	if fb.called {
		t.Error("bearer resolver was consulted although a valid X-Api-Key was present — key must win")
	}

	// (2) invalid key + valid bearer → 401, bearer NOT consulted (no fallthrough).
	fb.called, reached, gotCID = false, false, 0
	req = httptest.NewRequest("GET", "/v1/operator-po-list", nil)
	req.Header.Set("X-Api-Key", "wrong")
	req.Header.Set("Authorization", "Bearer tok-A")
	rr = httptest.NewRecorder()
	mw.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized || reached {
		t.Errorf("invalid key + valid bearer: code=%d reached=%v; want 401 reached=false", rr.Code, reached)
	}
	if fb.called {
		t.Error("bearer resolver was consulted after a bad X-Api-Key — a supplied key is authoritative, no fallthrough")
	}
}
