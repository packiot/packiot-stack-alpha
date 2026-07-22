// auth.go — the single tenant-injection authority for barcode-service.
//
// INVARIANT (identical discipline to refdata-api's ADR-0027 Surface-1):
// credential → id_enterprise → context. The client NEVER names a tenant — not
// in the body, not in the query, not in a header. The server derives
// id_enterprise from a verified JWT and every write is fenced by it.
//
// ISSUER-AGNOSTIC DUAL VERIFICATION
// ─────────────────────────────────
// The stack is mid-migration Firebase → Cognito (ADR-0034). Rather than branch
// on a deploy flag, the authenticator is issuer-agnostic: it peeks the token's
// unverified `iss`, routes to the verifier that OWNS that issuer, and only then
// verifies the signature + claims. Two verifiers are registered:
//
//   - Firebase (auth_firebase.go): iss = securetoken.google.com/<project>.
//     Tenant derived SERVER-SIDE from the users table by uid — the browser
//     holds no tenant id.
//   - Cognito  (auth_cognito.go):  iss = cognito-idp.<region>.amazonaws.com/<pool>.
//     Tenant carried as the custom:id_enterprise claim (ADR-0034 model).
//
// FAIL-CLOSED, exhaustively: no bearer → 401; unknown issuer → 401; bad
// signature / expired / wrong-audience → 401; verified token that resolves to
// no positive id_enterprise → 401. There is no fall-through to "no tenant
// filter" and no code path where the client's own claim of a tenant is trusted.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Identity is what a verified credential resolves to. EnterpriseID is the
// server-derived tenant (always > 0 for a successful auth); Subject/Issuer are
// carried for logging/audit only — never for authorization.
type Identity struct {
	EnterpriseID int
	Subject      string
	Issuer       string
}

// issuerVerifier is one relying-party binding: it claims an issuer and knows how
// to fully verify a token from it and derive the tenant. Both Firebase and
// Cognito implement it, so adding a third IdP later is one more registration.
type issuerVerifier interface {
	// issuerMatches reports whether this verifier owns tokens whose iss is `iss`.
	issuerMatches(iss string) bool
	// authenticate fully verifies the raw JWT and returns the derived identity.
	// Any failure (signature, claims, tenant resolution) is an error → 401.
	authenticate(ctx context.Context, raw string) (Identity, error)
}

// authenticator is the ordered set of registered verifiers.
type authenticator struct {
	verifiers []issuerVerifier
	logger    *slog.Logger
}

// newAuthenticator wires the verifiers enabled by config. A verifier is only
// registered when its config is present, so an empty COGNITO_ISSUER leaves the
// Cognito path entirely off (and vice-versa for Firebase). If BOTH are empty
// the authenticator authenticates nothing → every write 401s (fail-closed).
func newAuthenticator(cfg config, pool *pgxpool.Pool, logger *slog.Logger) *authenticator {
	a := &authenticator{logger: logger}
	if cfg.firebaseProject != "" {
		a.verifiers = append(a.verifiers, newFirebaseVerifier(cfg.firebaseProject, dbEnterpriseByUID(pool), nil))
	}
	if cfg.cognitoIssuer != "" {
		a.verifiers = append(a.verifiers, newCognitoVerifier(cfg.cognitoIssuer, cfg.cognitoAudience, nil))
	}
	logger.Info("auth configured",
		slog.Bool("firebase", cfg.firebaseProject != ""),
		slog.Bool("cognito", cfg.cognitoIssuer != ""),
		slog.Int("verifiers", len(a.verifiers)))
	return a
}

// resolve peeks the token's issuer, routes to the owning verifier, and returns
// the derived identity. Unknown/absent issuer → errUnknownIssuer (→ 401). The
// peek is UNVERIFIED — it only selects a verifier; the selected verifier does
// the real signature + claims check, so a forged iss just picks a verifier that
// will then reject the bad signature.
func (a *authenticator) resolve(ctx context.Context, raw string) (Identity, error) {
	iss, err := peekIssuer(raw)
	if err != nil {
		return Identity{}, err
	}
	for _, v := range a.verifiers {
		if v.issuerMatches(iss) {
			id, err := v.authenticate(ctx, raw)
			if err != nil {
				return Identity{}, err
			}
			if id.EnterpriseID <= 0 { // defence-in-depth: never inject a non-positive tenant
				return Identity{}, errUnknownTenant
			}
			return id, nil
		}
	}
	return Identity{}, errUnknownIssuer
}

// middleware enforces auth in front of a handler: extract the Bearer token,
// resolve → Identity, inject id_enterprise into the request context. Every
// failure is a uniform 401 that never reveals WHICH check failed (no oracle for
// probing tokens/issuers).
func (a *authenticator) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok, err := bearerToken(r)
		if err != nil {
			unauthorized(w)
			return
		}
		id, err := a.resolve(r.Context(), tok)
		if err != nil {
			a.logger.Warn("auth rejected", slog.String("err", err.Error()))
			unauthorized(w)
			return
		}
		next.ServeHTTP(w, r.WithContext(withEnterpriseID(r.Context(), id.EnterpriseID)))
	})
}

// ── context plumbing — the resolved tenant travels middleware → handler ──────

type ctxKey int

const enterpriseIDKey ctxKey = 0

func withEnterpriseID(ctx context.Context, id int) context.Context {
	return context.WithValue(ctx, enterpriseIDKey, id)
}

// enterpriseIDFromContext returns the server-resolved tenant. ok=false is
// unreachable behind middleware, but handlers still check it so a scoped write
// can never run without a tenant (fail-closed by construction).
func enterpriseIDFromContext(ctx context.Context) (int, bool) {
	id, ok := ctx.Value(enterpriseIDKey).(int)
	return id, ok
}

// ── shared helpers ───────────────────────────────────────────────────────────

// peekIssuer parses the token WITHOUT verifying its signature and returns the
// `iss` claim. Used only to select a verifier; the chosen verifier then does
// the real cryptographic check.
func peekIssuer(raw string) (string, error) {
	var claims jwt.RegisteredClaims
	parser := jwt.NewParser()
	if _, _, err := parser.ParseUnverified(raw, &claims); err != nil {
		return "", err
	}
	if claims.Issuer == "" {
		return "", errNoIssuer
	}
	return claims.Issuer, nil
}

// bearerToken extracts the raw JWT from `Authorization: Bearer <jwt>`.
// Case-insensitive on the scheme (RFC 7235). Absent/non-Bearer → errNoBearer.
func bearerToken(r *http.Request) (string, error) {
	h := r.Header.Get("Authorization")
	if h == "" {
		return "", errNoBearer
	}
	const prefix = "bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return "", errNoBearer
	}
	tok := strings.TrimSpace(h[len(prefix):])
	if tok == "" {
		return "", errNoBearer
	}
	return tok, nil
}

// unauthorized is the single 401 — generic, credential-agnostic, no oracle.
func unauthorized(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	http.Error(w, `{"error":"missing or invalid credentials"}`, http.StatusUnauthorized)
}
