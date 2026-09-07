// auth_operator_superadmin.go — the operator super-admin cross-tenant READ
// escalation (operator review HIGH #2).
//
// This is a DELIBERATE, flag-gated exception to the ADR-0027 Surface-1 invariant
// ("the client NEVER names a tenant"), and the READ twin of edge-api's write-
// plane exception (auth.middleware.ts + operator-superadmin-verifier.ts). Without
// it, a super-admin who switches the operator SPA onto another tenant gets that
// tenant's sidebar (from /session/switch) but the HOME tenant's PO/downtime/OEE
// reads — because refdata resolves the tenant from the FIXED nginx-injected
// api-key. That mismatch (see the wrong tenant, write to the right one) is why
// the switcher could not be turned on.
//
// TRUST MODEL — why letting the client name a tenant is safe HERE:
//
//	Auth is Cognito, always Cognito: the operator SPA authenticates to the
//	Cognito user pool via SRP and carries its Cognito ID token as the Bearer on
//	every call. A super-admin who has switched carries, on each /v1 read:
//	  - the FIXED api-key (nginx-injected) → proves the HOME tenant, AND
//	  - `x-operator-superadmin-token` = that same Cognito ID token, AND
//	  - `?idEnterprise=<target>`.
//	We honor <target> ONLY when ALL of these hold:
//	  1) OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED is on (else this whole file is
//	     inert — newOperatorSuperAdminAuth returns nil);
//	  2) the Cognito ID token VERIFIES (RS256 via JWKS, iss/aud/exp — the same
//	     verifier the main /v1 read path uses) AND carries a VERIFIED email — a
//	     forged/expired/unverified token is rejected BEFORE any DB touch (the DoS
//	     gate); the identity is that verified email;
//	  3) that email is a LIVE user_roles.super_user in the DB, re-checked every
//	     request (never trusted from the token body → a de-escalated role loses
//	     cross-tenant power immediately);
//	  4) that user is on the exclusive email allowlist (default dev@packiot.com);
//	  5) the target enterprise exists AND is active.
//	Any failure ⇒ DENY the claim and fall back to the HOME tenant — never a 401,
//	never a leak. Byte-identical fail-closed semantics to the edge-api write path.
//	The $1 fence in makeHandler then scopes every query to whichever customer_id
//	we resolved, so a granted target is fenced exactly like any normal tenant —
//	this changes WHICH tenant is bound as $1, never WHETHER $1 is bound.
//
// Dark by default: nil escalator (flag off or no Cognito verifier) is a no-op in
// authMiddleware, so /v1 behaves exactly as before (home key only).
package main

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

const defaultOperatorSuperAdminAllowlist = "dev@packiot.com"

// operatorSuperAdminAuth resolves the cross-tenant READ escalation. The two DB
// checks are injected closures (the codebase's dbEnterpriseLookup idiom) so the
// verifier is unit-testable without a live pool.
type operatorSuperAdminAuth struct {
	cognito            claimsVerifier
	allowlist          map[string]bool
	isLiveSuperUser    func(ctx context.Context, userName string) bool
	isEnterpriseActive func(ctx context.Context, idEnterprise int) bool
	logger             *slog.Logger
}

// newOperatorSuperAdminAuth builds the escalator, or returns nil (feature dark)
// when the capability flag is off or no Cognito verifier is available. A nil result makes the
// middleware skip the escalation entirely — fail-closed by absence.
func newOperatorSuperAdminAuth(pool *pgxpool.Pool, logger *slog.Logger, cognito claimsVerifier) *operatorSuperAdminAuth {
	if !getenvBool("OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED", false) {
		return nil
	}
	// Auth is Cognito, always Cognito: the escalation verifies the operator's
	// Cognito ID token (the same verifier the main /v1 read path uses). Without a
	// Cognito verifier (Firebase-only deploy / pool ids unset) it stays dark.
	if cognito == nil {
		logger.Warn("operator super-admin read escalation enabled but Cognito verifier unavailable — staying dark")
		return nil
	}
	return &operatorSuperAdminAuth{
		cognito:            cognito,
		allowlist:          parseSuperAdminAllowlist(getenv("OPERATOR_SUPERADMIN_ALLOWLIST", defaultOperatorSuperAdminAllowlist)),
		isLiveSuperUser:    dbSuperUserCheck(pool),
		isEnterpriseActive: dbEnterpriseActiveCheck(pool),
		logger:             logger,
	}
}

// parseSuperAdminAllowlist mirrors edge-api resolveSuperAdminAllowlist: comma-
// separated, trimmed, lowercased; empty falls back to the default (never an
// empty allowlist that would deny everyone, and never a wildcard).
func parseSuperAdminAllowlist(raw string) map[string]bool {
	if strings.TrimSpace(raw) == "" {
		raw = defaultOperatorSuperAdminAllowlist
	}
	out := map[string]bool{}
	for _, p := range strings.Split(raw, ",") {
		if e := strings.ToLower(strings.TrimSpace(p)); e != "" {
			out[e] = true
		}
	}
	if len(out) == 0 {
		out[defaultOperatorSuperAdminAllowlist] = true
	}
	return out
}

// resolveTarget returns (targetEnterpriseID, true) when the request carries a
// valid super-admin escalation naming a DIFFERENT, active tenant than home;
// otherwise (0, false) — the caller keeps the home customer_id. It never fails
// the request: a missing/forged/unauthorized claim silently stays home.
func (a *operatorSuperAdminAuth) resolveTarget(ctx context.Context, r *http.Request, homeCID int) (int, bool) {
	tokenStr := strings.TrimSpace(r.Header.Get("x-operator-superadmin-token"))
	if tokenStr == "" {
		return 0, false
	}
	target, err := strconv.Atoi(strings.TrimSpace(r.URL.Query().Get("idEnterprise")))
	if err != nil || target <= 0 || target == homeCID {
		// No cross-tenant intent (or the target IS home): cheapest exit, no verify.
		return 0, false
	}
	// 1) Signature — verify the operator's Cognito ID token (RS256 via JWKS,
	// iss/aud/exp) before any DB touch. This is the SAME token the operator
	// carries as its Bearer (Cognito, always Cognito) — not an edge-api HS256 JWT.
	// The identity is the token's VERIFIED email; an unverified mailbox is
	// rejected (the allowlist/super_user match is by email, so an unconfirmed
	// address would be an account-takeover vector).
	vc, err := a.cognito.VerifyClaims(ctx, tokenStr)
	if err != nil || vc.email == "" || !vc.emailVerified {
		return 0, false
	}
	user := strings.ToLower(strings.TrimSpace(vc.email))
	if user == "" {
		return 0, false
	}
	// 2) Exclusive email allowlist (default dev@packiot.com).
	if !a.allowlist[strings.ToLower(user)] {
		return 0, false
	}
	// 3) LIVE super_user (re-checked every request) AND 4) target is active.
	if !a.isLiveSuperUser(ctx, user) || !a.isEnterpriseActive(ctx, target) {
		return 0, false
	}
	return target, true
}

// dbSuperUserCheck is the production live-super_user closure — the authority is
// user_roles.super_user, never the token body. Mirrors edge-api's
// OperatorSuperAdminVerifier.verify DB query. Any error (incl. no such user)
// fails closed. A nil pool disables the escalation (returns a never-true check).
func dbSuperUserCheck(pool *pgxpool.Pool) func(context.Context, string) bool {
	if pool == nil {
		return func(context.Context, string) bool { return false }
	}
	return func(ctx context.Context, identityEmail string) bool {
		var super bool
		// Match the VERIFIED token email against the user_email column (not
		// user_name), and bool_or ACROSS all rows for that email: the same person
		// legitimately has rows in several enterprises (a product tenant + the
		// admin tenant that carries the super_user role), so "is this email a
		// super_user anywhere?" must aggregate rather than pick one arbitrary row.
		// Previously this matched user_name, which only worked because the admin
		// row abused user_name to hold the email — a fragile coupling now removed.
		err := pool.QueryRow(ctx,
			`SELECT COALESCE(bool_or(ur.super_user), false)
			   FROM users u
			   LEFT JOIN user_roles ur ON ur.id_user_role = u.user_roles
			  WHERE lower(u.user_email) = lower($1) AND u.active IS NOT FALSE`,
			identityEmail).Scan(&super)
		if err != nil {
			return false
		}
		return super
	}
}

// dbEnterpriseActiveCheck is the production active-enterprise closure. Mirrors
// OperatorSuperAdminVerifier.isEnterpriseActive. A nil pool disables it.
func dbEnterpriseActiveCheck(pool *pgxpool.Pool) func(context.Context, int) bool {
	if pool == nil {
		return func(context.Context, int) bool { return false }
	}
	return func(ctx context.Context, idEnterprise int) bool {
		var one int
		err := pool.QueryRow(ctx,
			`SELECT 1 FROM enterprises WHERE id_enterprise = $1 AND active = true LIMIT 1`,
			idEnterprise).Scan(&one)
		return err == nil
	}
}
