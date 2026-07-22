// auth_cognito.go — the Amazon Cognito relying-party verifier (ADR-0034).
//
// A Cognito ID/access token is an RS256 JWT signed by the user pool. Like
// Firebase, verification is PUBLIC-KEY only: fetch the pool's JWKS
// (<issuer>/.well-known/jwks.json), select the key by kid, verify signature +
// standard claims (iss, exp/iat, and aud when an app-client id is configured).
//
// TENANT DERIVATION — the one deliberate difference from Firebase: Cognito
// carries the tenant as a NATIVE custom attribute surfaced as the token claim
// `custom:id_enterprise` (see terraform/staging/cognito.tf). So the tenant is
// read from the VERIFIED claim rather than a DB lookup — but it is still
// SERVER-DERIVED in the sense that matters: it comes from a claim the pool
// signed, never from anything the HTTP client can set. A token without a
// positive custom:id_enterprise resolves to no tenant → 401 (fail-closed).
//
// PHASE-2: if the team later chooses a DB-lookup binding over the claim (the
// cognito.tf comment leaves that open), swap resolveEnterprise for the same
// users-table lookup the Firebase path uses — the issuerVerifier seam is
// unchanged.
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
	"strconv"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// cognitoVerifier verifies tokens from one Cognito user pool and derives the
// tenant from the custom:id_enterprise claim. Implements issuerVerifier.
type cognitoVerifier struct {
	iss      string // https://cognito-idp.<region>.amazonaws.com/<poolId>
	audience string // app-client id; "" ⇒ audience check skipped (Phase-0 lenient)
	keys     *jwksCache
}

func newCognitoVerifier(issuer, audience string, client *http.Client) *cognitoVerifier {
	return &cognitoVerifier{
		iss:      issuer,
		audience: audience,
		keys:     newJWKSCache(issuer+"/.well-known/jwks.json", client),
	}
}

func (v *cognitoVerifier) issuerMatches(iss string) bool { return iss == v.iss }

func (v *cognitoVerifier) authenticate(ctx context.Context, raw string) (Identity, error) {
	opts := []jwt.ParserOption{
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithIssuer(v.iss),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(60 * time.Second),
	}
	if v.audience != "" {
		opts = append(opts, jwt.WithAudience(v.audience))
	}
	claims := jwt.MapClaims{}
	if _, err := jwt.ParseWithClaims(raw, claims, v.keyfunc(ctx), opts...); err != nil {
		return Identity{}, err
	}
	eid, err := enterpriseFromClaims(claims)
	if err != nil {
		return Identity{}, err
	}
	sub, _ := claims.GetSubject()
	return Identity{EnterpriseID: eid, Subject: sub, Issuer: v.iss}, nil
}

// enterpriseFromClaims reads the tenant from the signed custom:id_enterprise
// claim. Cognito can serialize a custom attribute as either a JSON string or a
// number, so both are accepted; anything that isn't a positive integer → error
// (fail-closed, never a default tenant).
func enterpriseFromClaims(claims jwt.MapClaims) (int, error) {
	v, ok := claims["custom:id_enterprise"]
	if !ok {
		return 0, errNoEntClaim
	}
	switch t := v.(type) {
	case string:
		n, err := strconv.Atoi(t)
		if err != nil || n <= 0 {
			return 0, errUnknownTenant
		}
		return n, nil
	case float64: // JSON numbers decode to float64
		n := int(t)
		if n <= 0 {
			return 0, errUnknownTenant
		}
		return n, nil
	default:
		return 0, errUnknownTenant
	}
}

func (v *cognitoVerifier) keyfunc(ctx context.Context) jwt.Keyfunc {
	return func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errKeyNotFound
		}
		return v.keys.keyForKID(ctx, kid)
	}
}

// ── JWKS cache (RFC 7517 JSON Web Key Set) ───────────────────────────────────
//
// Cognito publishes its signing keys as a JWKS: an array of JWKs each with a
// modulus (n) and exponent (e) in base64url. We build *rsa.PublicKey from those
// two fields. Same single-flight refresh discipline as the Firebase x509 cache,
// but the Cognito endpoint sends no useful Cache-Control, so we use a fixed TTL
// and force a refresh on an unknown kid (rotation).
type jwksCache struct {
	url    string
	client *http.Client
	ttl    time.Duration

	mu     sync.RWMutex
	keys   map[string]*rsa.PublicKey
	expiry time.Time
}

func newJWKSCache(url string, client *http.Client) *jwksCache {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &jwksCache{url: url, client: client, ttl: time.Hour}
}

func (c *jwksCache) keyForKID(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c.mu.RLock()
	k, ok := c.keys[kid]
	fresh := time.Now().Before(c.expiry)
	c.mu.RUnlock()
	if ok && fresh {
		return k, nil
	}
	if err := c.refresh(ctx); err != nil {
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

// jwk is one RFC 7517 RSA key entry.
type jwk struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func (c *jwksCache) refresh(ctx context.Context) error {
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
		return fmt.Errorf("cognito jwks: status %d", resp.StatusCode)
	}
	var doc struct {
		Keys []jwk `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return fmt.Errorf("cognito jwks: decode: %w", err)
	}
	keys := make(map[string]*rsa.PublicKey, len(doc.Keys))
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || k.Kid == "" {
			continue
		}
		pub, err := jwkToRSA(k)
		if err != nil {
			continue // skip one unparsable key; don't fail the whole refresh
		}
		keys[k.Kid] = pub
	}
	if len(keys) == 0 {
		return errors.New("cognito jwks: no usable RSA keys")
	}
	c.keys = keys
	c.expiry = time.Now().Add(c.ttl)
	return nil
}

// jwkToRSA reconstructs an RSA public key from a JWK's base64url modulus (n) and
// exponent (e).
func jwkToRSA(k jwk) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, err
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, err
	}
	e := 0
	for _, b := range eBytes {
		e = e<<8 | int(b)
	}
	if e == 0 {
		return nil, errors.New("jwk: zero exponent")
	}
	return &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: e}, nil
}
