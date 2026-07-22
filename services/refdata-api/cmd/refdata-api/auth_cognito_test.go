package main

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	testCognitoIss    = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt"
	testCognitoClient = "2ckuoa0ov598rdpdn3uv039h6e"
)

// jwksBody serializes an RSA public key as a one-key JWK Set — the exact shape
// Cognito serves at <issuer>/.well-known/jwks.json (n/e base64url, NOT a cert).
func jwksBody(kid string, pub *rsa.PublicKey) string {
	n := base64.RawURLEncoding.EncodeToString(pub.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes())
	return fmt.Sprintf(`{"keys":[{"kty":"RSA","kid":%q,"use":"sig","alg":"RS256","n":%q,"e":%q}]}`, kid, n, e)
}

// cognitoVerifierWithKey builds a cognitoVerifier whose JWKS cache is pre-loaded
// (no network) — isolates the CLAIM/token_use/audience logic from the fetch path.
func cognitoVerifierWithKey(pub *rsa.PublicKey) *cognitoVerifier {
	return &cognitoVerifier{
		iss:      testCognitoIss,
		clientID: testCognitoClient,
		keys: &jwksCache{
			keys: map[string]*rsa.PublicKey{testKID: pub},
			// A freshly-loaded cache: expiry in the future AND lastRefresh=now, so
			// the unknown-kid throttle holds and no fetch is attempted (there is no
			// client/url here) — an unknown kid resolves to errKeyNotFound offline.
			expiry:      time.Now().Add(time.Hour),
			lastRefresh: time.Now(),
		},
		acceptedUse: map[string]bool{"id": true, "access": true},
	}
}

func cognitoIDClaims() jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss":       testCognitoIss,
		"aud":       testCognitoClient,
		"token_use": "id",
		"sub":       "cog-sub-123",
		"iat":       now.Add(-time.Minute).Unix(),
		"exp":       now.Add(time.Hour).Unix(),
	}
}

func cognitoAccessClaims() jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss":       testCognitoIss,
		"client_id": testCognitoClient, // access tokens carry client_id, NOT aud
		"token_use": "access",
		"sub":       "cog-sub-123",
		"iat":       now.Add(-time.Minute).Unix(),
		"exp":       now.Add(time.Hour).Unix(),
	}
}

// TestCognitoVerifyClaimChecks is the security core for the Cognito path: a
// correctly-signed id token with the right pool claims verifies to its sub;
// every tampered dimension (aud, iss, exp, token_use, alg, signature, sub) is
// rejected. Also proves the access-token audience branch (client_id claim).
func TestCognitoVerifyClaimChecks(t *testing.T) {
	key, _ := genKeyCert(t)
	v := cognitoVerifierWithKey(&key.PublicKey)
	ctx := context.Background()

	t.Run("valid id token → sub", func(t *testing.T) {
		sub, err := v.Verify(ctx, mintRS256(t, key, testKID, cognitoIDClaims()))
		if err != nil || sub != "cog-sub-123" {
			t.Fatalf("got sub=%q err=%v; want cog-sub-123, nil", sub, err)
		}
	})

	t.Run("valid access token (client_id branch) → sub", func(t *testing.T) {
		sub, err := v.Verify(ctx, mintRS256(t, key, testKID, cognitoAccessClaims()))
		if err != nil || sub != "cog-sub-123" {
			t.Fatalf("got sub=%q err=%v; want cog-sub-123, nil", sub, err)
		}
	})

	reject := func(name string, base func() jwt.MapClaims, mutate func(jwt.MapClaims), signKey *rsa.PrivateKey, kid string) {
		t.Run(name, func(t *testing.T) {
			c := base()
			mutate(c)
			if _, err := v.Verify(ctx, mintRS256(t, signKey, kid, c)); err == nil {
				t.Fatalf("%s: expected rejection, got nil", name)
			}
		})
	}
	reject("wrong audience (id token, other client)", cognitoIDClaims, func(c jwt.MapClaims) { c["aud"] = "other-client" }, key, testKID)
	reject("wrong client_id (access token)", cognitoAccessClaims, func(c jwt.MapClaims) { c["client_id"] = "other-client" }, key, testKID)
	reject("wrong issuer (another pool)", cognitoIDClaims, func(c jwt.MapClaims) {
		c["iss"] = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_evilpool"
	}, key, testKID)
	reject("expired", cognitoIDClaims, func(c jwt.MapClaims) { c["exp"] = time.Now().Add(-time.Hour).Unix() }, key, testKID)
	reject("missing exp", cognitoIDClaims, func(c jwt.MapClaims) { delete(c, "exp") }, key, testKID)
	reject("empty subject", cognitoIDClaims, func(c jwt.MapClaims) { c["sub"] = "" }, key, testKID)
	reject("unknown token_use (refresh)", cognitoIDClaims, func(c jwt.MapClaims) { c["token_use"] = "refresh" }, key, testKID)
	reject("missing token_use", cognitoIDClaims, func(c jwt.MapClaims) { delete(c, "token_use") }, key, testKID)
	reject("id token missing aud", cognitoIDClaims, func(c jwt.MapClaims) { delete(c, "aud") }, key, testKID)
	reject("unknown kid", cognitoIDClaims, func(c jwt.MapClaims) {}, key, "no-such-kid")

	// Signature forged with a DIFFERENT key but the trusted kid → rejected.
	otherKey, _ := genKeyCert(t)
	reject("signature from wrong key", cognitoIDClaims, func(c jwt.MapClaims) {}, otherKey, testKID)

	// token_use gate can be narrowed: an "access"-disabled verifier rejects it.
	t.Run("access rejected when only id accepted", func(t *testing.T) {
		idOnly := cognitoVerifierWithKey(&key.PublicKey)
		idOnly.acceptedUse = map[string]bool{"id": true}
		if _, err := idOnly.Verify(ctx, mintRS256(t, key, testKID, cognitoAccessClaims())); err == nil {
			t.Fatal("access token accepted by an id-only verifier")
		}
	})

	// Algorithm substitution: an HS256 token must be rejected by WithValidMethods.
	t.Run("alg substitution HS256", func(t *testing.T) {
		hs := jwt.NewWithClaims(jwt.SigningMethodHS256, cognitoIDClaims())
		hs.Header["kid"] = testKID
		s, err := hs.SignedString([]byte("secret"))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := v.Verify(ctx, s); err == nil {
			t.Fatal("HS256 token accepted — alg substitution not blocked")
		}
	})

	// Unconfigured verifier (no client/iss) fails closed before any parse.
	t.Run("unconfigured verifier fails closed", func(t *testing.T) {
		empty := &cognitoVerifier{acceptedUse: map[string]bool{"id": true}}
		if _, err := empty.Verify(ctx, mintRS256(t, key, testKID, cognitoIDClaims())); err != errCognitoNotConf {
			t.Fatalf("got err=%v; want errCognitoNotConf", err)
		}
	})
}

// TestJWKSCacheFetchAndVerify exercises the REAL fetch → parse(n,e) → verify
// path against a local server that mimics Cognito's JWKS endpoint, including
// cache reuse (TTL) and refresh-on-unknown-kid (rotation).
func TestJWKSCacheFetchAndVerify(t *testing.T) {
	key, _ := genKeyCert(t)
	var hits int
	body := jwksBody(testKID, &key.PublicKey)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	v := &cognitoVerifier{
		iss:         testCognitoIss,
		clientID:    testCognitoClient,
		keys:        newJWKSCache(srv.URL, time.Hour, srv.Client()),
		acceptedUse: map[string]bool{"id": true, "access": true},
	}
	sub, err := v.Verify(context.Background(), mintRS256(t, key, testKID, cognitoIDClaims()))
	if err != nil || sub != "cog-sub-123" {
		t.Fatalf("fetch+verify: sub=%q err=%v", sub, err)
	}
	// Second verify must reuse the cache (fresh for the TTL), not refetch.
	if _, err := v.Verify(context.Background(), mintRS256(t, key, testKID, cognitoIDClaims())); err != nil {
		t.Fatalf("second verify: %v", err)
	}
	if hits != 1 {
		t.Errorf("jwks endpoint hit %d times; want 1 (cache should serve the second verify)", hits)
	}

	// Unknown-kid THROTTLE: a token with a kid the cache lacks, presented while
	// the set is still fresh AND within the throttle window, must NOT trigger a
	// fetch (DoS guard) — it is rejected without touching the network.
	newKey, _ := genKeyCert(t)
	body = jwksBody("rotated-kid", &newKey.PublicKey)
	if _, err := v.Verify(context.Background(), mintRS256(t, newKey, "rotated-kid", cognitoIDClaims())); err == nil {
		t.Fatal("unknown-kid token accepted before rotation was published/throttle elapsed")
	}
	if hits != 1 {
		t.Errorf("jwks endpoint hit %d times during throttle window; want 1 (no forced refetch)", hits)
	}

	// Rotation pickup: once the throttle interval has elapsed (simulated by
	// ageing lastRefresh), the unknown kid forces exactly one refresh and the
	// endpoint — now serving the rotated key — makes the new token verify.
	v.keys.mu.Lock()
	v.keys.lastRefresh = time.Now().Add(-2 * jwksMinRefreshInterval)
	v.keys.mu.Unlock()
	sub, err = v.Verify(context.Background(), mintRS256(t, newKey, "rotated-kid", cognitoIDClaims()))
	if err != nil || sub != "cog-sub-123" {
		t.Fatalf("post-rotation verify: sub=%q err=%v", sub, err)
	}
	if hits != 2 {
		t.Errorf("jwks endpoint hit %d times after rotation; want 2 (one forced refresh on unknown kid)", hits)
	}
}

// TestAudienceHas covers the RFC 7519 aud shapes (string and array).
func TestAudienceHas(t *testing.T) {
	cases := []struct {
		aud  any
		want string
		ok   bool
	}{
		{"client-a", "client-a", true},
		{"client-a", "client-b", false},
		{[]any{"x", "client-a"}, "client-a", true},
		{[]any{"x", "y"}, "client-a", false},
		{[]string{"client-a"}, "client-a", true},
		{nil, "client-a", false},
		{42, "client-a", false},
	}
	for _, c := range cases {
		if got := audienceHas(c.aud, c.want); got != c.ok {
			t.Errorf("audienceHas(%v, %q) = %v; want %v", c.aud, c.want, got, c.ok)
		}
	}
}

// TestMultiVerifierDispatch proves the dual-accept seam: a Firebase token routes
// to the Firebase verifier, a Cognito token routes to the Cognito verifier, each
// gets the correct subject, and a token from an UNKNOWN issuer falls through to
// try-each and is rejected. This is the no-regression guarantee for the cutover.
func TestMultiVerifierDispatch(t *testing.T) {
	fbKey, _ := genKeyCert(t)
	cogKey, _ := genKeyCert(t)
	ctx := context.Background()

	fb := verifierWithKey(&fbKey.PublicKey) // firebase (testIss/testProject)
	cog := cognitoVerifierWithKey(&cogKey.PublicKey)

	mv := newMultiVerifier(
		namedVerifier{idp: "firebase", iss: testIss, v: fb},
		namedVerifier{idp: "cognito", iss: testCognitoIss, v: cog},
	)

	t.Run("firebase token still verifies (no regression)", func(t *testing.T) {
		uid, err := mv.Verify(ctx, mintRS256(t, fbKey, testKID, goodClaims()))
		if err != nil || uid != "uid-abc" {
			t.Fatalf("firebase via multi: uid=%q err=%v; want uid-abc", uid, err)
		}
	})

	t.Run("cognito token resolves to its sub", func(t *testing.T) {
		sub, err := mv.Verify(ctx, mintRS256(t, cogKey, testKID, cognitoIDClaims()))
		if err != nil || sub != "cog-sub-123" {
			t.Fatalf("cognito via multi: sub=%q err=%v; want cog-sub-123", sub, err)
		}
	})

	t.Run("a cognito token is NOT accepted by the firebase verifier alone", func(t *testing.T) {
		// Dispatch must route by issuer: a cognito-signed token handed to the
		// firebase-only verifier fails (wrong iss/aud) — proving isolation.
		if _, err := fb.Verify(ctx, mintRS256(t, cogKey, testKID, cognitoIDClaims())); err == nil {
			t.Fatal("firebase verifier accepted a cognito token")
		}
	})

	t.Run("unknown issuer → rejected via try-each fallback", func(t *testing.T) {
		claims := cognitoIDClaims()
		claims["iss"] = "https://evil.example.com/pool"
		if _, err := mv.Verify(ctx, mintRS256(t, cogKey, testKID, claims)); err == nil {
			t.Fatal("token with unknown issuer was accepted")
		}
	})
}

// TestUnverifiedIssuer confirms the routing read returns the iss without
// verifying, and "" on garbage (→ try-each fallback).
func TestUnverifiedIssuer(t *testing.T) {
	key, _ := genKeyCert(t)
	tok := mintRS256(t, key, testKID, cognitoIDClaims())
	if got := unverifiedIssuer(tok); got != testCognitoIss {
		t.Errorf("unverifiedIssuer = %q; want %q", got, testCognitoIss)
	}
	if got := unverifiedIssuer("not-a-jwt"); got != "" {
		t.Errorf("unverifiedIssuer(garbage) = %q; want empty", got)
	}
}

// TestUsersEnterpriseSQLUnifiedLookup locks in the ADR-0034 dual-IdP mapping:
// the tenant query must match EITHER id column so a Cognito sub OR a Firebase
// uid resolves through the SAME hardened, fail-closed lookup.
func TestUsersEnterpriseSQLUnifiedLookup(t *testing.T) {
	sql := usersEnterpriseSQL
	for _, must := range []string{"id_user_firebase = $1", "id_user_cognito = $1", "active = true", "id_enterprise IS NOT NULL"} {
		if !contains(sql, must) {
			t.Errorf("usersEnterpriseSQL missing clause %q:\n%s", must, sql)
		}
	}
}
