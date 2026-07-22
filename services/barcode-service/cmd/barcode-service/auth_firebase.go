// auth_firebase.go — the Firebase relying-party verifier.
//
// A Firebase ID token is an RS256 JWT signed by Google. Verification is
// PUBLIC-KEY only: fetch Google's rotating x509 certs, check signature +
// standard claims (iss/aud/exp/iat/sub). We never mint tokens, so there is no
// secret in this service. The signature check is also the DoS gate — a forged
// token is rejected before the uid→enterprise DB lookup ever runs.
//
// Tenant derivation is SERVER-SIDE: the verified uid is looked up in the users
// table (id_user_firebase → id_enterprise), hardened exactly as refdata-api's
// task #68 (active=true, id_enterprise IS NOT NULL). The browser supplies no
// tenant. This mirrors refdata's auth_firebase.go so the two services agree on
// what "authenticated as enterprise N" means.
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
// service account — the rotating RS256 signing certs. Public, so a constant.
const firebaseCertURL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"

// defaultFirebaseProject — overridable via FIREBASE_PROJECT_ID (config, not
// hard-coded policy). back4-api's databaseURL is https://fbpackiot.firebaseio.com.
const defaultFirebaseProject = "fbpackiot"

// usersEnterpriseSQL maps a verified Firebase uid → id_enterprise, hardened per
// refdata-api task #68: id_user_firebase is UNIQUE (≤1 row), active=true (a
// deactivated user's still-valid token can't resolve), id_enterprise IS NOT
// NULL (no default/NULL tenant). Zero rows ⇒ errUnknownUID ⇒ 401.
const usersEnterpriseSQL = `SELECT id_enterprise FROM users
	WHERE id_user_firebase = $1 AND active = true AND id_enterprise IS NOT NULL`

// Package-wide auth errors. Every one maps to a uniform 401 at the middleware —
// the caller never learns which check failed.
var (
	errNoBearer      = errors.New("no bearer token")
	errNoIssuer      = errors.New("token has no issuer")
	errUnknownIssuer = errors.New("token issuer is not a registered relying party")
	errUnknownTenant = errors.New("token resolves to no enterprise")
	errEmptySubject  = errors.New("token has no subject (uid)")
	errUnknownUID    = errors.New("uid resolves to no enterprise")
	errKeyNotFound   = errors.New("no signing key for token kid")
	errNoEntClaim    = errors.New("token has no custom:id_enterprise claim")
)

// enterpriseLookup resolves a verified Firebase uid → id_enterprise. Injected so
// the whole path is unit-testable without a DB; the production impl runs
// usersEnterpriseSQL over the pool.
type enterpriseLookup func(ctx context.Context, uid string) (int, error)

// dbEnterpriseByUID is the production uid→enterprise resolver.
func dbEnterpriseByUID(pool *pgxpool.Pool) enterpriseLookup {
	return func(ctx context.Context, uid string) (int, error) {
		var eid int
		err := pool.QueryRow(ctx, usersEnterpriseSQL, uid).Scan(&eid)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, errUnknownUID
		}
		if err != nil {
			return 0, err
		}
		return eid, nil
	}
}

// firebaseVerifier verifies a Firebase ID token for one project and resolves the
// tenant. Implements issuerVerifier.
type firebaseVerifier struct {
	projectID string
	iss       string // "https://securetoken.google.com/<projectID>"
	keys      *certCache
	lookup    enterpriseLookup
}

func newFirebaseVerifier(projectID string, lookup enterpriseLookup, client *http.Client) *firebaseVerifier {
	return &firebaseVerifier{
		projectID: projectID,
		iss:       "https://securetoken.google.com/" + projectID,
		keys:      newCertCache(firebaseCertURL, client),
		lookup:    lookup,
	}
}

func (v *firebaseVerifier) issuerMatches(iss string) bool { return iss == v.iss }

// authenticate verifies signature + claims, then derives the tenant from the
// uid server-side.
func (v *firebaseVerifier) authenticate(ctx context.Context, raw string) (Identity, error) {
	uid, err := v.verify(ctx, raw)
	if err != nil {
		return Identity{}, err
	}
	eid, err := v.lookup(ctx, uid)
	if err != nil {
		return Identity{}, err
	}
	return Identity{EnterpriseID: eid, Subject: uid, Issuer: v.iss}, nil
}

// verify checks alg=RS256, signature, exp/iat, aud=project, iss, and a
// non-empty sub (the uid). 60s leeway for clock skew.
func (v *firebaseVerifier) verify(ctx context.Context, raw string) (string, error) {
	tok, err := jwt.Parse(raw, v.keyfunc(ctx),
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

func (v *firebaseVerifier) keyfunc(ctx context.Context) jwt.Keyfunc {
	return func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errKeyNotFound
		}
		return v.keys.keyForKID(ctx, kid)
	}
}

// ── x509 signing-cert cache (Firebase's JWKS-equivalent) ─────────────────────
//
// Holds the current kid→RSA-public-key set fetched from Google's x509 endpoint,
// refreshed when the HTTP Cache-Control max-age elapses or a requested kid is
// absent (rotation). An RWMutex guards the map; refresh takes the write lock so
// it single-flights (no thundering herd on expiry).
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

func (c *certCache) keyForKID(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c.mu.RLock()
	k, ok := c.keys[kid]
	fresh := time.Now().Before(c.expiry)
	c.mu.RUnlock()
	if ok && fresh {
		return k, nil
	}
	if err := c.refresh(ctx); err != nil {
		if ok { // serve a stale key rather than hard-fail on a transient Google blip
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

func (c *certCache) refresh(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Now().Before(c.expiry) && len(c.keys) > 0 {
		return nil // a concurrent refresh already repopulated
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
			continue // skip one bad entry; don't fail the whole refresh
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

// cacheMaxAge parses max-age (seconds) from a Cache-Control header; 1h fallback
// so a rotated-out key can never be pinned forever.
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
