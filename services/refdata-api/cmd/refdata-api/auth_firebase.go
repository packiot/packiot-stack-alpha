// auth_firebase.go — task #68: the per-user Firebase-JWT tenant path.
//
// front4 is a STATIC SPA: it holds no shared secret and must never name a
// tenant. It already carries a per-user Firebase ID token (the same one it
// sends to Hasura + back4/primary-api) as `Authorization: Bearer <jwt>`. This
// file makes refdata-api a SECOND relying party for that identity, ALONGSIDE
// the X-Api-Key map (auth.go): verify the token, take its uid (sub), and
// resolve the tenant SERVER-SIDE via the users table — the same mapping
// back4-api already uses (`SELECT id_enterprise FROM users WHERE
// id_user_firebase = $1`), HARDENED (see usersEnterpriseSQL). The browser
// supplies neither a tenant id nor a key.
//
// Trust model — why no service-account secret is needed:
//
//	A Firebase ID token is an RS256 JWT signed by Google. Verification is
//	PUBLIC-KEY: fetch Google's rotating x509 certs, check the signature and
//	the standard claims (iss/aud/exp/iat/sub). We never mint tokens, only
//	verify them, so there is no private key or credential in this service.
//	The signature check is also the DoS gate: an unsigned/forged token is
//	rejected before any DB lookup, so only real fbpackiot users ever reach
//	the uid→enterprise query.
//
// Lib choice: github.com/golang-jwt/jwt/v5 — the de-facto Go JWT library,
// vetted and ubiquitous — plus a ~60-line x509 key cache. Rationale over the
// firebase.google.com/go SDK: that SDK pulls ~40 transitive deps (google.
// golang.org/api, cloud.google.com/go/…) into a service whose whole ethos is
// "one lean binary, minimal go.mod". golang-jwt gives full control over the
// exact x509 endpoint + Cache-Control refresh the task requires, and keeps
// the verifier unit-testable without a network by injecting the keyfunc.
package main

import (
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// firebaseCertURL is Google's PUBLIC x509 endpoint for the securetoken system
// service account — the source of the rotating RS256 signing certs for every
// Firebase project. Public data, so it is a constant, not a secret/env value.
const firebaseCertURL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"

// defaultFirebaseProject is the Firebase project id (back4-api's databaseURL
// is https://fbpackiot.firebaseio.com). Overridable via env
// (FIREBASE_PROJECT_ID) so the value is config, never hard-coded policy.
const defaultFirebaseProject = "fbpackiot"

// usersEnterpriseSQL maps a verified Firebase uid → tenant. It is back4-api's
// mapping HARDENED on DBA advice (staging+prod confirmed, task #68):
//   - id_user_firebase is UNIQUE ⇒ at most one row (the core safety property);
//   - active = true         ⇒ a deactivated user with a still-valid token can
//     no longer resolve their old tenant (back4-api omits this — we diverge
//     deliberately, consistent with the CS-Admin soft-delete direction);
//   - id_enterprise IS NOT NULL ⇒ the 4 prod rows with a uid but no enterprise
//     yield ZERO rows, so we reject rather than inject a NULL/absent tenant.
//
// Zero rows ⇒ errUnknownUID ⇒ 401. Never a default tenant.
const usersEnterpriseSQL = `SELECT id_enterprise FROM users
	WHERE id_user_firebase = $1 AND active = true AND id_enterprise IS NOT NULL`

var (
	errNoBearer     = errors.New("no bearer token")
	errEmptySubject = errors.New("token has no subject (uid)")
	errUnknownUID   = errors.New("uid resolves to no enterprise")
	errKeyNotFound  = errors.New("no signing key for token kid")
)

// bearerToken extracts the raw JWT from an `Authorization: Bearer <jwt>`
// header. Case-insensitive on the scheme (RFC 7235). Returns errNoBearer when
// the header is absent or not a Bearer credential, so the middleware can tell
// "no bearer offered" (fall through) from "bad bearer" (401).
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

// ── Firebase ID-token verifier ────────────────────────────────────────────

// firebaseVerifier verifies a Firebase ID token for one project and returns
// its uid (the `sub` claim). Offline/public-key verification only.
type firebaseVerifier struct {
	projectID string
	iss       string // precomputed "https://securetoken.google.com/<projectID>"
	keys      *certCache
}

func newFirebaseVerifier(projectID string, client *http.Client) *firebaseVerifier {
	return &firebaseVerifier{
		projectID: projectID,
		iss:       "https://securetoken.google.com/" + projectID,
		keys:      newCertCache(firebaseCertURL, client),
	}
}

// Verify checks signature + standard claims and returns the uid. Every failure
// path returns an error (the middleware maps ALL of them to 401 — the caller
// never learns which check failed). Checks, per the Firebase spec:
//   - alg == RS256                         (WithValidMethods — blocks alg-swap)
//   - signature valid for the token's kid  (keyfunc against the x509 cache)
//   - exp present and in the future        (WithExpirationRequired)
//   - iat not in the future                (WithIssuedAt)
//   - aud == projectID                     (WithAudience)
//   - iss == securetoken.google.com/<proj> (WithIssuer)
//   - sub non-empty                        (explicit — it is the uid)
//
// A 60s leeway absorbs clock skew between us and Google (industry standard).
func (v *firebaseVerifier) Verify(ctx context.Context, tokenStr string) (string, error) {
	tok, err := jwt.Parse(tokenStr, v.keyfunc(ctx),
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithIssuer(v.iss),
		jwt.WithAudience(v.projectID),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(60*time.Second),
	)
	if err != nil {
		return "", err
	}
	sub, err := tok.Claims.GetSubject()
	if err != nil {
		return "", err
	}
	if sub == "" {
		return "", errEmptySubject
	}
	return sub, nil
}

// keyfunc returns the jwt.Keyfunc that maps a token's `kid` header to the
// matching RSA public key from the cache (refreshing on rotation). Bound to a
// ctx so the cert fetch honors the request's deadline/cancellation.
func (v *firebaseVerifier) keyfunc(ctx context.Context) jwt.Keyfunc {
	return func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errKeyNotFound
		}
		return v.keys.keyForKID(ctx, kid)
	}
}

// ── x509 signing-cert cache (JWKS-equivalent for Firebase) ─────────────────

// certCache holds the current kid→RSA-public-key set fetched from Google's
// x509 endpoint, refreshed when the HTTP Cache-Control max-age elapses or a
// requested kid is absent (rotation). Concurrency: an RWMutex guards the map;
// refresh takes the write lock so it single-flights (no thundering herd when
// many requests race an expiry).
type certCache struct {
	url    string
	client *http.Client

	mu     sync.RWMutex
	keys   map[string]*rsa.PublicKey
	expiry time.Time
}

func newCertCache(url string, client *http.Client) *certCache {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &certCache{url: url, client: client}
}

// keyForKID returns the RSA public key for kid, refreshing the cache if it is
// stale or the kid is unknown (a just-rotated key). One forced refresh per
// miss: if the kid is still absent afterward, the token is signed by a key
// Google isn't publishing → reject.
func (c *certCache) keyForKID(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c.mu.RLock()
	k, ok := c.keys[kid]
	fresh := time.Now().Before(c.expiry)
	c.mu.RUnlock()
	if ok && fresh {
		return k, nil
	}
	if err := c.refresh(ctx); err != nil {
		// If the fetch failed but we still hold a (stale) key for this kid,
		// serve it rather than hard-failing on a transient Google blip.
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

// refresh fetches the x509 cert map and parses each PEM cert into an RSA
// public key. The response body is a flat JSON object {kid: "<PEM cert>"}.
// Cache lifetime comes from the response's Cache-Control max-age (Google sets
// it to when the next rotation is due); a missing/zero max-age falls back to a
// conservative 1h so we never pin a rotated-out key indefinitely.
func (c *certCache) refresh(ctx context.Context) error {
	// Re-check under the write lock: a concurrent refresh may have already
	// populated a fresh set while we waited for the lock (single-flight).
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Now().Before(c.expiry) && len(c.keys) > 0 {
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
		return fmt.Errorf("firebase certs: status %d", resp.StatusCode)
	}
	var raw map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return fmt.Errorf("firebase certs: decode: %w", err)
	}
	keys := make(map[string]*rsa.PublicKey, len(raw))
	for kid, certPEM := range raw {
		pub, err := parseRSACert(certPEM)
		if err != nil {
			// Skip an unparsable cert rather than failing the whole refresh —
			// one bad entry must not take down verification for the others.
			continue
		}
		keys[kid] = pub
	}
	if len(keys) == 0 {
		return errors.New("firebase certs: no usable keys in response")
	}
	c.keys = keys
	c.expiry = time.Now().Add(cacheMaxAge(resp.Header.Get("Cache-Control")))
	return nil
}

// parseRSACert decodes a PEM certificate and returns its RSA public key.
func parseRSACert(certPEM string) (*rsa.PublicKey, error) {
	block, _ := pem.Decode([]byte(certPEM))
	if block == nil {
		return nil, errors.New("not PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	pub, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("cert public key is not RSA")
	}
	return pub, nil
}

// cacheMaxAge parses the max-age (seconds) out of a Cache-Control header.
// Returns a 1h fallback when absent/unparseable so a rotated key can never be
// pinned forever.
func cacheMaxAge(cc string) time.Duration {
	const fallback = time.Hour
	for _, part := range strings.Split(cc, ",") {
		part = strings.TrimSpace(part)
		if v, ok := strings.CutPrefix(part, "max-age="); ok {
			if secs, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && secs > 0 {
				return time.Duration(secs) * time.Second
			}
		}
	}
	return fallback
}

// ── uid → customer_id resolver (cached, DB-backed) ─────────────────────────

// verifier is the token-verification seam the resolver depends on — an
// interface so tests can inject a mock (task #68 §5: "mock the verifier").
type verifier interface {
	Verify(ctx context.Context, token string) (uid string, err error)
}

// firebaseBearerAuth composes the two halves of the Bearer path: verify the
// token → uid, then resolve uid → customer_id (id_enterprise). Both must
// succeed; either failure is a 401 at the middleware. Its resolve method is
// the concrete bearerResolver wired into authMiddleware in main.go.
//
// Both seams are injected (verify, lookup) so the whole path is unit-testable
// without a live Firebase project or DB: tests supply a fake verifier + fake
// lookup and assert the tenant is derived from the verified uid.
type firebaseBearerAuth struct {
	verify verifier
	// lookup maps a verified uid → customer_id (id_enterprise). The production
	// impl is a closure over the pgx pool running usersEnterpriseSQL; tests
	// inject a fake. Unknown uid / deactivated / NULL enterprise → errUnknownUID.
	lookup func(ctx context.Context, uid string) (int, error)

	// positive-only TTL cache: uid → id_enterprise. Bounded lifetime so a
	// user's deactivation/enterprise move propagates within ttl. No negative
	// caching — a valid-token-but-unknown-uid is nearly impossible (the token
	// already proved a real fbpackiot identity), so the DB is not a flood risk.
	ttl   time.Duration
	mu    sync.RWMutex
	cache map[string]cacheEntry
}

type cacheEntry struct {
	cid int
	exp time.Time
}

func newFirebaseBearerAuth(v verifier, pool *pgxpool.Pool, ttl time.Duration) *firebaseBearerAuth {
	return &firebaseBearerAuth{
		verify: v,
		lookup: dbEnterpriseLookup(pool),
		ttl:    ttl,
		cache:  map[string]cacheEntry{},
	}
}

// dbEnterpriseLookup is the production uid→enterprise resolver: the hardened
// usersEnterpriseSQL. Zero rows (unknown uid, deactivated user, or NULL
// enterprise) → errUnknownUID → 401.
func dbEnterpriseLookup(pool *pgxpool.Pool) func(context.Context, string) (int, error) {
	return func(ctx context.Context, uid string) (int, error) {
		var cid int
		err := pool.QueryRow(ctx, usersEnterpriseSQL, uid).Scan(&cid)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, errUnknownUID
		}
		if err != nil {
			return 0, err
		}
		return cid, nil
	}
}

// resolve is the bearerResolver signature the middleware calls: raw JWT →
// customer_id. Fail-closed at every step — unknown uid, NULL/absent
// enterprise, deactivated user, and any verify error all return an error
// (→ 401), never a default tenant.
func (a *firebaseBearerAuth) resolve(ctx context.Context, tokenStr string) (int, error) {
	uid, err := a.verify.Verify(ctx, tokenStr)
	if err != nil {
		return 0, err
	}
	if cid, ok := a.cacheGet(uid); ok {
		return cid, nil
	}
	cid, err := a.lookup(ctx, uid)
	if err != nil {
		return 0, err
	}
	a.cachePut(uid, cid)
	return cid, nil
}

func (a *firebaseBearerAuth) cacheGet(uid string) (int, bool) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	e, ok := a.cache[uid]
	if !ok || time.Now().After(e.exp) {
		return 0, false
	}
	return e.cid, true
}

func (a *firebaseBearerAuth) cachePut(uid string, cid int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.cache[uid] = cacheEntry{cid: cid, exp: time.Now().Add(a.ttl)}
}
