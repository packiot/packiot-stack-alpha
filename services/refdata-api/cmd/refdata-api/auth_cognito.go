// auth_cognito.go — ADR-0034: the SECOND per-user IdP relying-party path.
//
// WHY THIS EXISTS
// ───────────────
// ADR-0034 migrates front4's identity provider from Firebase to an AWS Cognito
// user pool. During the cutover BOTH IdPs are live: some browser sessions still
// carry a Firebase ID token, some already carry a Cognito token. This file makes
// refdata-api a relying party for the Cognito identity ALONGSIDE Firebase
// (auth_firebase.go) and the X-Api-Key operator map (auth.go). The two Bearer
// paths are DUAL-ACCEPTED (multiVerifier below) — never a flag-day swap — so the
// cutover is reversible: verify EITHER token, take its `sub`, resolve the tenant
// SERVER-SIDE via the users table. The browser still supplies neither a tenant
// id nor a secret.
//
// TRUST MODEL — same public-key posture as Firebase
// ─────────────────────────────────────────────────
//
//	A Cognito ID/access token is an RS256 JWT signed by the user pool. Like the
//	Firebase path we only VERIFY, never mint: fetch the pool's PUBLIC JWKS,
//	check the signature + standard claims (iss/exp/iat), the audience
//	(client_id), and `token_use`. No private key, no service-account secret.
//	The signature check is the DoS gate: a forged token is rejected before any
//	DB lookup, so only real pool users reach the sub→enterprise query.
//
// FORMAT DIFFERENCE vs Firebase
// ─────────────────────────────
//
//	Firebase serves its signing keys as an x509 CERT map ({kid: "<PEM>"}) from
//	Google's securetoken endpoint (auth_firebase.go's certCache). Cognito serves
//	a standard JWK SET ({"keys":[{kty,kid,n,e,…}]}) at
//	<issuer>/.well-known/jwks.json — RSA modulus/exponent, not a wrapped cert.
//	So this file carries its own jwksCache that reconstructs *rsa.PublicKey from
//	the base64url (n,e) pair. The RWMutex single-flight refresh pattern mirrors
//	certCache deliberately (same concurrency reasoning); the two are kept
//	SEPARATE rather than sharing a generalized cache so this additive change
//	never touches the proven Firebase path. Cognito rotates its signing keys
//	rarely and (unlike Google) sends no useful Cache-Control, so the TTL is a
//	fixed, configurable lifetime with refresh-on-unknown-kid for rotation.
package main

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Default STAGING Cognito pool identifiers (ADR-0034). All three are PUBLIC
// routing values — a user-pool id, an app-client id, and the issuer URL are not
// secrets (no signing key, no client secret). They are env-overridable
// (COGNITO_ISSUER / COGNITO_CLIENT_ID) so a different pool needs no rebuild; the
// defaults are the live staging pool so the service works if compose omits them.
const (
	defaultCognitoIssuer   = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt"
	defaultCognitoClientID = "2ckuoa0ov598rdpdn3uv039h6e"
)

// cognitoAuthEnabled reads COGNITO_AUTH_ENABLED. ADR-0034: DEFAULT ON — the
// staging pool is live and the path is DUAL-ACCEPT (Firebase keeps working), so
// an unset env safely enables Cognito verification alongside Firebase. Set the
// env to "false"/"0"/"off"/"no" to revert to Firebase-only (the reversible kill
// switch). Anything else — including unset/empty — is ON.
func cognitoAuthEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("COGNITO_AUTH_ENABLED"))) {
	case "false", "0", "off", "no":
		return false
	default:
		return true
	}
}

// defaultCognitoJWKSTTL is how long a fetched JWK set is trusted before a
// scheduled refresh. Cognito signing keys are effectively static (rotation is a
// rare, operator-driven event), and an unknown kid forces an out-of-band refresh
// anyway (keyForKID), so a long TTL is safe and keeps us off the network.
const defaultCognitoJWKSTTL = 12 * time.Hour

// jwksMinRefreshInterval rate-limits the UNKNOWN-KID refresh (the out-of-band
// path taken when a token names a kid the cache lacks). Without a cap, an
// attacker could spray random-kid tokens to force a JWKS fetch each time (a
// signature check never even runs — the kid lookup fails first), amplifying an
// unauthenticated request into an outbound fetch. Capping forced refetches to
// once per interval bounds that to ~1 fetch/interval while still picking up a
// REAL key rotation within the interval. (Firebase's certCache instead leans on
// Google's short Cache-Control to align its TTL with rotation; Cognito sends no
// such header, so we cap explicitly.)
const jwksMinRefreshInterval = 1 * time.Minute

var (
	errWrongTokenUse  = errors.New("token_use not accepted")
	errWrongAudience  = errors.New("token audience/client_id mismatch")
	errBadClaims      = errors.New("token claims not a map")
	errNoVerifier     = errors.New("no verifier accepted the token")
	errCognitoNotConf = errors.New("cognito verifier not configured")
)

// ── Cognito ID/access-token verifier ───────────────────────────────────────

// cognitoVerifier verifies a Cognito user-pool JWT and returns its `sub` (the
// pool user's immutable UUID — the value we map to users.id_user_cognito).
// Offline/public-key verification only. It satisfies the `verifier` interface
// (auth_firebase.go), so it drops straight into the same resolver seam.
type cognitoVerifier struct {
	iss      string // the pool issuer: https://cognito-idp.<region>.amazonaws.com/<poolID>
	clientID string // the app client id — the audience an id token must carry
	keys     *jwksCache

	// acceptedUse gates which token_use values verify. Amplify's API category
	// sends the ID token (token_use="id") to APIs, so "id" is the primary path;
	// "access" is accepted too (defense per ADR-0034 — a service that forwards
	// an access token still resolves) with the client_id validated from the
	// access token's `client_id` claim instead of `aud`.
	acceptedUse map[string]bool
}

// newCognitoVerifier builds a verifier for one user pool + app client. issuer is
// the pool issuer URL; the JWKS URL is derived from it (<issuer>/.well-known/
// jwks.json) unless jwksURL is non-empty (test override). A nil client uses a
// default 10s-timeout http.Client.
func newCognitoVerifier(issuer, clientID, jwksURL string, client *http.Client) *cognitoVerifier {
	if jwksURL == "" {
		jwksURL = issuer + "/.well-known/jwks.json"
	}
	return &cognitoVerifier{
		iss:      issuer,
		clientID: clientID,
		keys:     newJWKSCache(jwksURL, defaultCognitoJWKSTTL, client),
		// Accept BOTH id and access by default — Amplify sends id; access is a
		// documented fallback. Both are validated against the SAME app client.
		acceptedUse: map[string]bool{"id": true, "access": true},
	}
}

// Verify checks signature + standard claims + Cognito-specific claims and
// returns the `sub`. Every failure returns an error (the middleware maps ALL of
// them to 401 — the caller never learns which check failed). Checks:
//   - alg == RS256                     (WithValidMethods — blocks alg-swap)
//   - signature valid for token's kid  (keyfunc against the JWKS cache)
//   - exp present and in the future    (WithExpirationRequired)
//   - iat not in the future            (WithIssuedAt)
//   - iss == pool issuer               (WithIssuer)
//   - token_use ∈ acceptedUse          (explicit — Cognito-specific)
//   - audience matches the app client  (aud for id tokens, client_id for access)
//   - sub non-empty                    (explicit — it is the uid)
//
// NOTE the audience is validated MANUALLY (not jwt.WithAudience): an id token
// carries the client in `aud`, but a Cognito ACCESS token has NO `aud` — it
// carries the client in a `client_id` claim. A single WithAudience can't express
// that split, so we branch on token_use. A 60s leeway absorbs clock skew.
func (v *cognitoVerifier) Verify(ctx context.Context, tokenStr string) (string, error) {
	if v.clientID == "" || v.iss == "" {
		return "", errCognitoNotConf
	}
	tok, err := jwt.Parse(tokenStr, v.keyfunc(ctx),
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithIssuer(v.iss),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(60*time.Second),
	)
	if err != nil {
		return "", err
	}
	claims, ok := tok.Claims.(jwt.MapClaims)
	if !ok {
		return "", errBadClaims
	}

	use, _ := claims["token_use"].(string)
	if !v.acceptedUse[use] {
		return "", errWrongTokenUse
	}
	// Audience check keyed on token_use (see method doc).
	switch use {
	case "id":
		// `aud` may be a string or []string per RFC 7519 — accept either.
		if !audienceHas(claims["aud"], v.clientID) {
			return "", errWrongAudience
		}
	case "access":
		if cid, _ := claims["client_id"].(string); cid != v.clientID {
			return "", errWrongAudience
		}
	}

	sub, err := claims.GetSubject()
	if err != nil {
		return "", err
	}
	if sub == "" {
		return "", errEmptySubject
	}
	return sub, nil
}

// audienceHas reports whether the JWT `aud` claim (a string or a []string, per
// RFC 7519) contains want.
func audienceHas(aud any, want string) bool {
	switch a := aud.(type) {
	case string:
		return a == want
	case []any:
		for _, e := range a {
			if s, ok := e.(string); ok && s == want {
				return true
			}
		}
	case []string:
		for _, s := range a {
			if s == want {
				return true
			}
		}
	}
	return false
}

// keyfunc maps a token's `kid` header to the matching RSA public key from the
// JWKS cache (refreshing on rotation). Bound to ctx so the fetch honors the
// request deadline.
func (v *cognitoVerifier) keyfunc(ctx context.Context) jwt.Keyfunc {
	return func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errKeyNotFound
		}
		return v.keys.keyForKID(ctx, kid)
	}
}

// ── JWKS cache (RSA n/e → *rsa.PublicKey) ──────────────────────────────────

// jwkKey is one entry of a JWK Set. Only the RSA-signature fields matter here.
type jwkKey struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"` // base64url RSA modulus
	E   string `json:"e"` // base64url RSA exponent
}

type jwkSet struct {
	Keys []jwkKey `json:"keys"`
}

// jwksCache holds the current kid→RSA-public-key set fetched from a pool's JWKS
// endpoint, refreshed when the TTL elapses or a requested kid is absent
// (rotation). Concurrency mirrors certCache: an RWMutex guards the map; refresh
// takes the write lock so it single-flights (no thundering herd on expiry).
type jwksCache struct {
	url    string
	ttl    time.Duration
	client *http.Client

	mu          sync.RWMutex
	keys        map[string]*rsa.PublicKey
	expiry      time.Time // TTL horizon for a SCHEDULED refresh
	lastRefresh time.Time // last successful fetch — throttles the unknown-kid path
}

func newJWKSCache(url string, ttl time.Duration, client *http.Client) *jwksCache {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	if ttl <= 0 {
		ttl = defaultCognitoJWKSTTL
	}
	return &jwksCache{url: url, ttl: ttl, client: client}
}

// keyForKID returns the RSA public key for kid, refreshing if the cache is stale
// or the kid is unknown (a just-rotated key). One forced refresh per miss: if
// the kid is still absent, the token is signed by a key the pool isn't
// publishing → reject.
func (c *jwksCache) keyForKID(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c.mu.RLock()
	k, ok := c.keys[kid]
	fresh := time.Now().Before(c.expiry)
	c.mu.RUnlock()
	if ok && fresh {
		return k, nil
	}
	if err := c.refresh(ctx, kid); err != nil {
		// Serve a stale key on a transient fetch blip rather than hard-failing.
		if ok {
			return k, nil
		}
		return nil, err
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	if k, ok := c.keys[kid]; ok {
		return k, nil
	}
	return nil, errKeyNotFound
}

// refresh fetches the JWK set and reconstructs each RSA public key from its
// (n,e) pair. Single-flighted under the write lock. wantKID is the kid that
// triggered this call (may be ""); it lets refresh decide whether a concurrent
// refresh already satisfied us and enforce the unknown-kid throttle.
func (c *jwksCache) refresh(ctx context.Context, wantKID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	// A concurrent refresh may have already produced the wanted key in a set
	// that is still fresh — then there is nothing to do (single-flight).
	if wantKID != "" {
		if _, ok := c.keys[wantKID]; ok && time.Now().Before(c.expiry) {
			return nil
		}
	}
	// Set still fresh (TTL not elapsed) but we're here for a MISSING kid → this
	// is the unknown-kid path. Throttle it so unauthenticated random-kid tokens
	// can't drive a fetch storm; a real rotation is still picked up within the
	// interval. (When the set is STALE we always proceed — the scheduled refresh.)
	if len(c.keys) > 0 && time.Now().Before(c.expiry) &&
		time.Since(c.lastRefresh) < jwksMinRefreshInterval {
		return nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
	if err != nil {
		return err
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("cognito jwks: status %d", resp.StatusCode)
	}
	var set jwkSet
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return fmt.Errorf("cognito jwks: decode: %w", err)
	}
	keys := make(map[string]*rsa.PublicKey, len(set.Keys))
	for _, jwk := range set.Keys {
		if jwk.Kty != "RSA" || jwk.Kid == "" {
			continue // only RSA signing keys are usable here
		}
		pub, err := rsaPublicKeyFromJWK(jwk)
		if err != nil {
			// Skip one unparsable key rather than failing the whole refresh.
			continue
		}
		keys[jwk.Kid] = pub
	}
	if len(keys) == 0 {
		return errors.New("cognito jwks: no usable RSA keys in response")
	}
	c.keys = keys
	now := time.Now()
	c.expiry = now.Add(c.ttl)
	c.lastRefresh = now
	return nil
}

// rsaPublicKeyFromJWK reconstructs an *rsa.PublicKey from a JWK's base64url
// (n,e) pair. Cognito uses RawURLEncoding (no padding) per RFC 7518.
func rsaPublicKeyFromJWK(jwk jwkKey) (*rsa.PublicKey, error) {
	nb, err := base64.RawURLEncoding.DecodeString(jwk.N)
	if err != nil {
		return nil, fmt.Errorf("jwk n: %w", err)
	}
	eb, err := base64.RawURLEncoding.DecodeString(jwk.E)
	if err != nil {
		return nil, fmt.Errorf("jwk e: %w", err)
	}
	if len(nb) == 0 || len(eb) == 0 {
		return nil, errors.New("jwk: empty modulus/exponent")
	}
	e := new(big.Int).SetBytes(eb)
	if !e.IsInt64() || e.Int64() <= 0 {
		return nil, errors.New("jwk: bad exponent")
	}
	return &rsa.PublicKey{
		N: new(big.Int).SetBytes(nb),
		E: int(e.Int64()),
	}, nil
}

// ── multi-IdP verifier (dual-accept during the cutover) ─────────────────────

// namedVerifier pairs a verifier with the issuer string used to ROUTE a token
// to it (cheap unverified `iss` read — routing only; the chosen verifier still
// does the full signature+claims check).
type namedVerifier struct {
	idp string   // "firebase" | "cognito" (for logging/metrics later)
	iss string   // exact iss claim this verifier owns
	v   verifier // the concrete impl
}

// multiVerifier is the DUAL-ACCEPT seam (ADR-0034): it verifies a Bearer token
// against whichever configured IdP issued it. It satisfies the `verifier`
// interface, so firebaseBearerAuth.resolve consumes it unchanged — the uid it
// returns (a Firebase uid OR a Cognito sub) flows into the SAME unified
// uid→tenant lookup (usersEnterpriseSQL matches either id column).
//
// Dispatch: read the token's `iss` UNVERIFIED (routing only) and hand it to the
// verifier that owns that issuer — so a Firebase token is checked ONLY by the
// Firebase verifier and a Cognito token ONLY by Cognito, giving each the correct
// error and avoiding needless cross-checks. If the iss matches none (or is
// unreadable), fall back to trying each verifier in order — every attempt is a
// full cryptographic verify, so the fallback is safe, just less efficient.
type multiVerifier struct {
	verifiers []namedVerifier
}

// newMultiVerifier builds a dual verifier from an ordered list. Firebase should
// come first (the incumbent) so the fallback path favors it.
func newMultiVerifier(vs ...namedVerifier) *multiVerifier {
	return &multiVerifier{verifiers: vs}
}

func (m *multiVerifier) Verify(ctx context.Context, tokenStr string) (string, error) {
	if iss := unverifiedIssuer(tokenStr); iss != "" {
		for _, nv := range m.verifiers {
			if nv.iss == iss {
				return nv.v.Verify(ctx, tokenStr) // authoritative single check
			}
		}
	}
	// No issuer match — try each (full verify each time), return first success.
	var lastErr error = errNoVerifier
	for _, nv := range m.verifiers {
		if uid, err := nv.v.Verify(ctx, tokenStr); err == nil {
			return uid, nil
		} else {
			lastErr = err
		}
	}
	return "", lastErr
}

// unverifiedIssuer parses the token WITHOUT verifying its signature to read the
// `iss` claim FOR ROUTING ONLY. This is not a trust decision — the routed
// verifier re-parses with full signature+claims validation. A malformed token
// yields "" and falls through to the try-each path (which will reject it).
func unverifiedIssuer(tokenStr string) string {
	p := jwt.NewParser()
	var claims jwt.MapClaims
	if _, _, err := p.ParseUnverified(tokenStr, &claims); err != nil {
		return ""
	}
	iss, _ := claims["iss"].(string)
	return iss
}
