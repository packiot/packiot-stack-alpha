package main

import (
	"context"
	"encoding/json"
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
// dataset, regardless of the request body — the client cannot move it. A
// present role is supplied so the per-user-role datasets also compile and get
// their $1 checked here (their $2 server-derived-role invariant is pinned
// separately in TestRoleDatasetsBindTenantAndUserRoleAxes).
func TestCompiledArgsPinCustomerIDAtDollarOne(t *testing.T) {
	const tenantA, tenantB = 3, 4
	const someRole = 55
	for name, ds := range datasets {
		req := datasetReq{Dataset: name}
		if ds.windowed {
			// minimal valid window so compile doesn't reject on bounds
			req.Window = &dsWindow{From: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), To: time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)}
		}
		aSQL, aArgs, aErr := compileDataset(req, tenantA, callerRole{id: someRole, present: true})
		bSQL, bArgs, bErr := compileDataset(req, tenantB, callerRole{id: someRole, present: true})
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

// ── #58 front4→refdata migration: the net-new datasets are gate-classified ──
//
// TestEveryDatasetIsTenantScoped already covers ALL datasets structurally
// (that is the whole point of the gate — a new entry is fenced by
// construction). This test PINS the specific net-new datasets the #58 Phase
// 2-3 migration adds, so that a future refactor that renames or drops one is a
// visible failure here, not a silent coverage hole. Every listed dataset must
// exist, bind the injected tenant at $1, and — for the api_key-adjacent role
// views — never carry the secret.
func TestFront4MigrationDatasetsAreClassifiedTenantSafe(t *testing.T) {
	// The 12 net-new datasets (the 13th read, ScrapPeriod, folds into the
	// existing `single-period` dataset — same function, same args — and the
	// GET_TARGET/OEE_OBJ_MONTH/GET_SHIFT_PROD reads fold into
	// production-targets/scrap-targets/oee-targets/live-equipment-month/
	// live-equipment-shift; see the report).
	migration := []string{
		"home-uns",
		"events-timeline-from-po", "events-timeline-full",
		"production-orders-runtimes", "production-orders-with-runtimes",
		"entities-per-user-role", "menu-per-user-role",
		"equipment-downtime-reasons", "site-by-equipment",
		"custom-target-month", "custom-target-week", "custom-target-day",
	}
	for _, name := range migration {
		ds, ok := datasets[name]
		if !ok {
			t.Errorf("#58 migration dataset %q is missing from the registry", name)
			continue
		}
		// Same invariant the whole-registry gate enforces, pinned per name.
		if len(ds.params) == 0 || ds.params[0].kind != pEnterprise {
			t.Errorf("dataset %q: params[0] must be pEnterprise ($1)", name)
		}
		if !strings.Contains(ds.sql, "$1") {
			t.Errorf("dataset %q: SQL never binds the injected tenant $1:\n%s", name, ds.sql)
		}
		// The tenancy secret must never transit any migration dataset — this
		// catches a future edit that re-adds SELECT * on v_entities_per_user_role
		// (whose `enterprise` jsonb embeds api_key).
		if strings.Contains(ds.sql, "api_key") {
			t.Errorf("dataset %q: SQL references api_key — the tenancy secret must never transit this API", name)
		}
	}
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
	// auth-exempt). The exempt set is EXACTLY the infra probes plus the ADR-0031
	// external shims (routeExternalShim), which self-authenticate to reproduce a
	// foreign auth contract; nothing else may be exempt.
	exempt := authExemptSet()
	for path, class := range seen {
		if strings.HasPrefix(path, "/v1/") && exempt[path] {
			t.Errorf("route %q is a /v1 read but is auth-exempt — every read must resolve the tenant from the key", path)
		}
		switch class {
		case routeInfra, routeExternalShim:
			if !exempt[path] {
				t.Errorf("route %q (class %d) must be in the auth-exempt set", path, class)
			}
		default:
			if exempt[path] {
				t.Errorf("route %q is auth-exempt but is neither infra nor an external shim", path)
			}
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

// fakeBearer builds a bearerResolver from a token→resolvedIdentity table,
// recording whether it was invoked (to prove X-Api-Key precedence
// short-circuits it).
type fakeBearer struct {
	table  map[string]resolvedIdentity // token string → resolved identity (tenant + optional role)
	called bool
}

func (f *fakeBearer) resolve(_ context.Context, token string) (resolvedIdentity, error) {
	f.called = true
	id, ok := f.table[token]
	if !ok {
		return resolvedIdentity{}, errUnknownUID
	}
	return id, nil
}

// TestBearerPathResolvesTenantServerSide proves the JWT path binds the
// server-derived customer_id into context (→ $1), and fails closed on a bad or
// unknown token — the front4 SPA never supplies a tenant or a key.
func TestBearerPathResolvesTenantServerSide(t *testing.T) {
	fb := &fakeBearer{table: map[string]resolvedIdentity{"tok-A": {customerID: 11}, "tok-B": {customerID: 22}}}
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
	badResolver := func(context.Context, string) (resolvedIdentity, error) { return resolvedIdentity{}, errEmptySubject }
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
	fb := &fakeBearer{table: map[string]resolvedIdentity{"tok-A": {customerID: 99}}}
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

// ── task #70: the SECOND (per-user-role) scoping axis ──────────────────────
//
// The two variables-context bootstrap datasets are NOT tenant-wide: they bind
// a second, server-derived axis — the caller's id_user_role at $2 — on top of
// the tenant at $1. These tests widen the isolation gate to reason about that
// two-axis scoping while proving the existing single-axis property still holds
// for every other dataset.

// roleDatasets is the exact set expected to carry the per-user-role axis. A
// dataset that grows a pUserRole param without being listed here (or one here
// that loses it) fails the gate — the role surface can't drift silently.
var roleDatasets = map[string]bool{
	"entities-per-user-role": true,
	"menu-per-user-role":     true,
}

// TestRoleDatasetsBindTenantAndUserRoleAxes pins the two-axis contract:
//   - exactly the roleDatasets set carries a pUserRole param, and no other;
//   - for those, params are [pEnterprise($1), pUserRole($2)] in that order and
//     the SQL binds BOTH id_enterprise=$1 AND id_user_role=$2;
//   - pUserRole is server-derived: it has no filter name, so a client body can
//     neither set nor override it (proven by construction + a compile probe);
//   - every OTHER dataset keeps the single tenant axis (no pUserRole).
func TestRoleDatasetsBindTenantAndUserRoleAxes(t *testing.T) {
	for name, ds := range datasets {
		var nRole int
		for _, p := range ds.params {
			if p.kind == pUserRole {
				nRole++
				// Server-derived only: a pUserRole param must never be a named,
				// client-settable filter — that is what keeps $2 off the wire.
				if p.name != "" {
					t.Errorf("dataset %q: pUserRole param must have no filter name (server-derived, not client-supplied); got %q", name, p.name)
				}
			}
		}
		want := roleDatasets[name]
		if want && nRole != 1 {
			t.Errorf("dataset %q: expected exactly one pUserRole axis, got %d", name, nRole)
		}
		if !want && nRole != 0 {
			t.Errorf("dataset %q: unexpected pUserRole axis (%d) — only the variables-context role datasets take a user axis", name, nRole)
		}
		if !want {
			continue
		}
		// Two-axis shape: $1 tenant then $2 role, in order.
		if len(ds.params) != 2 || ds.params[0].kind != pEnterprise || ds.params[1].kind != pUserRole {
			t.Errorf("dataset %q: params must be [pEnterprise, pUserRole]; got %+v", name, ds.params)
		}
		if !strings.Contains(ds.sql, "id_enterprise = $1") || !strings.Contains(ds.sql, "id_user_role = $2") {
			t.Errorf("dataset %q: SQL must bind BOTH tenant ($1) and user_role ($2):\n%s", name, ds.sql)
		}
	}
}

// TestRoleDatasetsFailClosedWithoutUserContext proves the X-Api-Key decision
// (task #70 §3): a role dataset compiled without a resolved user identity —
// the operator path, or a role-less user — is rejected with
// errRoleDatasetNeedsUser (→ 403), never an unscoped tenant-wide role list.
// With a present role it compiles, binding the SERVER role at $2.
func TestRoleDatasetsFailClosedWithoutUserContext(t *testing.T) {
	for name := range roleDatasets {
		// No user context → fail closed.
		if _, _, err := compileDataset(datasetReq{Dataset: name}, 42, callerRole{present: false}); err != errRoleDatasetNeedsUser {
			t.Errorf("dataset %q without user context: err=%v; want errRoleDatasetNeedsUser (fail closed)", name, err)
		}
		// Present role → compiles; tenant at $1, server role at $2.
		sql, args, err := compileDataset(datasetReq{Dataset: name}, 42, callerRole{id: 77, present: true})
		if err != nil {
			t.Fatalf("dataset %q with user context: unexpected err %v", name, err)
		}
		if len(args) != 2 || args[0] != 42 || args[1] != 77 {
			t.Errorf("dataset %q: args must be [tenant 42, role 77]; got %v", name, args)
		}
		if !strings.Contains(sql, "id_user_role = $2") {
			t.Errorf("dataset %q: compiled SQL must scope id_user_role = $2:\n%s", name, sql)
		}
	}
}

// TestRoleAxisCannotBeClientSupplied proves $2 is never movable by the body:
// because pUserRole carries no filter name, ANY attempt to pass the role (or
// the tenant) through filters is rejected as an unaccepted filter — the client
// cannot inject or override the server-derived role.
func TestRoleAxisCannotBeClientSupplied(t *testing.T) {
	for name := range roleDatasets {
		for _, key := range []string{"id_user_role", "user_role", "id_enterprise", "role"} {
			req := datasetReq{Dataset: name, Filters: map[string]json.RawMessage{key: json.RawMessage(`9999`)}}
			if _, _, err := compileDataset(req, 42, callerRole{id: 77, present: true}); err == nil {
				t.Errorf("dataset %q accepted client-supplied filter %q — the role/tenant axes must be server-derived only", name, key)
			}
		}
	}
}

// TestBearerPathStashesUserRoleInContext proves the middleware plumbing: the
// Bearer path stashes the resolved id_user_role in context when present, omits
// it when the user is role-less, and the X-Api-Key path never sets it (so role
// datasets fail closed on the operator path — the two-axis fail-closed link).
func TestBearerPathStashesUserRoleInContext(t *testing.T) {
	fb := &fakeBearer{table: map[string]resolvedIdentity{
		"tok-role":   {customerID: 11, userRole: 5, hasRole: true},
		"tok-norole": {customerID: 12}, // hasRole false (NULL users.user_roles)
	}}
	var gotCID, gotRole int
	var roleOK bool
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotCID, _ = customerIDFromContext(r.Context())
		gotRole, roleOK = userRoleFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	mw := authMiddleware(map[string]int{"op-key": 9}, infraExemptSet(), fb.resolve, next)

	cases := []struct {
		name        string
		key         string // X-Api-Key ("" = unset)
		authz       string // Authorization ("" = unset)
		wantCID     int
		wantRole    int
		wantRoleSet bool
	}{
		{"bearer with role → cid+role stashed", "", "Bearer tok-role", 11, 5, true},
		{"bearer role-less → cid only, no role axis", "", "Bearer tok-norole", 12, 0, false},
		{"x-api-key → cid only, never a role axis", "op-key", "", 9, 0, false},
	}
	for _, c := range cases {
		gotCID, gotRole, roleOK = 0, 0, false
		req := httptest.NewRequest("GET", "/v1/query", nil)
		if c.key != "" {
			req.Header.Set("X-Api-Key", c.key)
		}
		if c.authz != "" {
			req.Header.Set("Authorization", c.authz)
		}
		mw.ServeHTTP(httptest.NewRecorder(), req)
		if gotCID != c.wantCID || roleOK != c.wantRoleSet || gotRole != c.wantRole {
			t.Errorf("%s: cid=%d role=%d roleSet=%v; want cid=%d role=%d roleSet=%v",
				c.name, gotCID, gotRole, roleOK, c.wantCID, c.wantRole, c.wantRoleSet)
		}
	}
}
