// auth.go — ADR-0027 Surface-1: the single tenant-injection authority.
//
// The invariant: credential → customer_id → $1. The client NEVER names a
// tenant (no path/query/body enterprise id). The server derives it from
// the credential and binds it as the first query parameter of every read.
//
// Generation B (query.go / datasets.go) already had this authority but
// applied it PER HANDLER; Generation A (main.go's fixed endpoints table)
// bypassed it entirely — the #57 hole. Surface-1 promotes `auth` to
// middleware in front of the WHOLE mux, so no route — legacy or new — can
// skip it, and makes the resolved customer_id travel to handlers via
// request context (never a handler arg the client could influence).
//
// task #68 adds a SECOND credential type behind the same authority: a
// per-user Firebase ID token (`Authorization: Bearer <jwt>`) for the static
// front4 SPA, which holds no shared key. The Bearer path (auth_firebase.go)
// verifies the token and derives the tenant from the users table server-side.
// Both credential types resolve to the SAME context-injected customer_id, so
// every downstream handler is identical no matter how the caller authed.
package main

import (
	"context"
	"net/http"
)

// routeClass classifies every mux route for BOTH the auth middleware
// (which paths to exempt) and the CI isolation gate (which routes must
// bind $1). One source of truth so the two can never disagree.
type routeClass int

const (
	// routeTenantScoped: behind auth; the backing SQL binds the resolved
	// customer_id as $1. A cross-tenant read is unrepresentable — there is
	// no request field that carries a tenant.
	routeTenantScoped routeClass = iota
	// routeGlobalRef: behind auth, but tenant-independent — global
	// reference data (language_packs i18n) or schema metadata (/v1/catalog)
	// that carries no tenant column. Explicitly enumerated, never a general
	// "unscoped is OK" carve-out.
	routeGlobalRef
	// routeInfra: NO auth — ops probes that expose no tenant data
	// (/healthz for the container healthcheck, /metrics for Prometheus).
	routeInfra
	// routeExternalShim: ADR-0031 Workstream B anti-corruption shims. EXEMPT
	// from this middleware — NOT because they skip authentication, but because
	// they must reproduce a FOREIGN auth contract's exact status shapes (back4's
	// missing-key → 400, unknown/wrong-owner → 401, both text/html) that this
	// middleware (which 401s uniformly as JSON) cannot express. Each shim self-
	// authenticates through the SAME QUERY_API_KEYS map (key → customer_id), so
	// refdata is still the single injection authority; the tenant fence is the
	// per-shim owner binding (external.go), gated by external_golden_test.go.
	routeExternalShim
)

// mountedRoute is one entry in the route manifest.
type mountedRoute struct {
	path  string
	class routeClass
}

// customerID context plumbing — the resolved tenant travels from the
// middleware to the handlers via request context.
type ctxKey int

const (
	customerIDKey ctxKey = 0
	// userRoleKey carries the caller's server-derived id_user_role (task #70).
	// ONLY the Firebase-JWT path sets it — the X-Api-Key operator path has no
	// user identity, so its absence is the fail-closed signal for the two
	// per-user-role bootstrap datasets. Never client-supplied.
	userRoleKey ctxKey = 1
)

func withCustomerID(ctx context.Context, id int) context.Context {
	return context.WithValue(ctx, customerIDKey, id)
}

func customerIDFromContext(ctx context.Context) (int, bool) {
	id, ok := ctx.Value(customerIDKey).(int)
	return id, ok
}

// withUserRole stashes the caller's single resolved id_user_role. Set only on
// the Bearer path, and only when the users row actually has a role (a NULL
// users.user_roles leaves it unset → role datasets fail closed).
func withUserRole(ctx context.Context, roleID int) context.Context {
	return context.WithValue(ctx, userRoleKey, roleID)
}

// userRoleFromContext returns the caller's id_user_role and whether one was
// resolved. ok=false means "no user axis" (X-Api-Key path, or a role-less
// user) — the role bootstrap datasets must reject rather than emit an
// unscoped, tenant-wide role list.
func userRoleFromContext(ctx context.Context) (int, bool) {
	id, ok := ctx.Value(userRoleKey).(int)
	return id, ok
}

// resolvedIdentity is what a credential resolves to server-side. Both
// credential types yield a customerID (the tenant → $1). ONLY the Firebase
// Bearer path yields a userRole (the caller's single id_user_role → $2 on the
// per-user-role bootstrap datasets); the X-Api-Key operator path has no user
// axis, so hasRole is false and role-scoped datasets fail closed. A user whose
// users.user_roles is NULL also resolves hasRole=false (tenant still valid, so
// every non-role dataset works; only the two role datasets reject).
type resolvedIdentity struct {
	customerID int
	userRole   int
	hasRole    bool
}

// queryAPIRoutes are the composable-query-API routes registered by
// registerQueryAPI (query.go). Listed here — alongside the endpoints table
// and infraRoutes — so the manifest is the ONE place that enumerates every
// mux route the isolation gate must vet.
var queryAPIRoutes = []mountedRoute{
	{"/v1/catalog", routeGlobalRef},          // schema metadata; tenant-independent, no DB tenant read
	{"/v1/query", routeTenantScoped},         // compile / compileDataset inject customer_id as $1
	{"/v1/screen-config", routeTenantScoped}, // scoped to id_enterprise = $1 (per-tenant layouts)
}

// infraRoutes are the unauthenticated ops probes — no tenant data.
var infraRoutes = []mountedRoute{
	{"/healthz", routeInfra},
	{"/metrics", routeInfra},
}

// routeManifest is the complete, classified set of every mux route — the
// single source of truth the auth middleware and the isolation gate share.
// A new route that isn't listed here (or an endpoint without a class) is a
// build failure in the gate, not a silent tenancy hole.
func routeManifest() []mountedRoute {
	m := make([]mountedRoute, 0, len(endpoints)+len(queryAPIRoutes)+len(infraRoutes)+len(externalShims))
	for _, ep := range endpoints {
		m = append(m, mountedRoute{ep.path, ep.class})
	}
	m = append(m, queryAPIRoutes...)
	m = append(m, infraRoutes...)
	m = append(m, externalRoutes()...) // ADR-0031 Workstream B (external.go)
	return m
}

// infraExemptSet is the set of paths the auth middleware lets through
// unauthenticated — EXACTLY the routeInfra routes, derived from the manifest
// so the exemption and the gate agree by construction.
func infraExemptSet() map[string]bool {
	exempt := map[string]bool{}
	for _, rt := range routeManifest() {
		if rt.class == routeInfra {
			exempt[rt.path] = true
		}
	}
	return exempt
}

// authExemptSet is what the auth middleware ACTUALLY lets through: the infra
// probes PLUS the external-contract shims (routeExternalShim), which self-
// authenticate to reproduce a foreign auth contract's exact status shapes. This
// is the middleware's exemption source of truth (main.go); the isolation gate
// asserts that only these two classes are ever exempt.
func authExemptSet() map[string]bool {
	exempt := map[string]bool{}
	for _, rt := range routeManifest() {
		if rt.class == routeInfra || rt.class == routeExternalShim {
			exempt[rt.path] = true
		}
	}
	return exempt
}

// bearerResolver verifies a `Authorization: Bearer` credential (a Firebase ID
// token) and returns the server-derived identity: the tenant (always) and,
// when the users row has one, the caller's id_user_role (task #70). A nil
// resolver disables the Bearer path entirely (X-Api-Key only). The concrete
// implementation is firebaseBearerAuth.resolve (auth_firebase.go).
type bearerResolver func(ctx context.Context, token string) (resolvedIdentity, error)

// authMiddleware resolves a credential → customer_id in front of the whole mux
// and injects it into the request context. Two credential types, ONE resolved
// tenant.
//
// Precedence (documented invariant): X-Api-Key WINS if present. A supplied
// X-Api-Key is authoritative — a bad one 401s rather than silently falling
// through to Bearer, so a caller can't probe both credential spaces in one
// request (confused-deputy avoidance). Only when NO X-Api-Key is offered do we
// try the Bearer token (the front4 SPA path).
//
// Fail-closed, exhaustively:
//   - infra routes pass through unauthenticated (healthcheck + scrape);
//   - X-Api-Key present but unknown → 401, no DB touch;
//   - no X-Api-Key, Bearer present but resolver nil (path disabled) → 401;
//   - no X-Api-Key, Bearer present but invalid/expired/wrong-project token, or
//     valid token whose uid maps to no active enterprise → 401, no tenant leak;
//   - neither credential offered → 401;
//   - an empty keys map AND a nil bearer resolver → EVERY non-infra route 401s.
//     A credential-source failure denies all access; it never falls through to
//     "no tenant filter".
func authMiddleware(keys map[string]int, exempt map[string]bool, bearer bearerResolver, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if exempt[r.URL.Path] {
			next.ServeHTTP(w, r)
			return
		}
		// 1) X-Api-Key is authoritative when present (operator/service creds).
		if raw := r.Header.Get("X-Api-Key"); raw != "" {
			cid, ok := keys[raw]
			if !ok {
				unauthorized(w)
				return
			}
			next.ServeHTTP(w, r.WithContext(withCustomerID(r.Context(), cid)))
			return
		}
		// 2) Else fall back to the Firebase Bearer token (front4 SPA). The
		// resolver derives BOTH the tenant and (task #70) the caller's single
		// id_user_role from the verified uid — both go into context. The role
		// is stashed only when present (a role-less user still authenticates
		// and reaches every non-role dataset); the two per-user-role datasets
		// read userRoleFromContext and fail closed when it is absent.
		if tok, err := bearerToken(r); err == nil {
			if bearer == nil {
				unauthorized(w)
				return
			}
			id, err := bearer(r.Context(), tok)
			if err != nil {
				unauthorized(w)
				return
			}
			ctx := withCustomerID(r.Context(), id.customerID)
			if id.hasRole {
				ctx = withUserRole(ctx, id.userRole)
			}
			next.ServeHTTP(w, r.WithContext(ctx))
			return
		}
		// 3) No usable credential.
		unauthorized(w)
	})
}

// unauthorized is the single 401 response — a generic message that never
// reveals which credential/claim failed (no oracle for token/key probing).
func unauthorized(w http.ResponseWriter) {
	http.Error(w, `{"error":"missing or invalid credentials"}`, http.StatusUnauthorized)
}
