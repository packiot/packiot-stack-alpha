package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	testProject = "fbpackiot"
	testIss     = "https://securetoken.google.com/fbpackiot"
	testKID     = "test-kid-1"
)

// genKeyCert makes an RSA key + a self-signed PEM cert wrapping its public key
// — the shape Google's x509 endpoint serves (a cert per kid, not a raw JWK).
func genKeyCert(t *testing.T) (*rsa.PrivateKey, string) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "securetoken-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return key, string(pemBytes)
}

// mintRS256 signs a token with the given key + kid and claims.
func mintRS256(t *testing.T, key *rsa.PrivateKey, kid string, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return s
}

func goodClaims() jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss": testIss,
		"aud": testProject,
		"sub": "uid-abc",
		"iat": now.Add(-time.Minute).Unix(),
		"exp": now.Add(time.Hour).Unix(),
	}
}

// verifierWithKey builds a firebaseVerifier whose cert cache is pre-loaded with
// pub (no network) — isolates the CLAIM/SIGNATURE logic from the fetch path.
func verifierWithKey(pub *rsa.PublicKey) *firebaseVerifier {
	return &firebaseVerifier{
		projectID: testProject,
		iss:       testIss,
		keys: &certCache{
			keys:   map[string]*rsa.PublicKey{testKID: pub},
			expiry: time.Now().Add(time.Hour),
		},
	}
}

// TestFirebaseVerifyClaimChecks is the security core: a correctly-signed token
// with the right project claims verifies to its uid; every tampered dimension
// (aud, iss, exp, iat, alg, signature, kid, sub) is rejected. This is where the
// "wrong-project token → 401" guarantee actually lives.
func TestFirebaseVerifyClaimChecks(t *testing.T) {
	key, _ := genKeyCert(t)
	v := verifierWithKey(&key.PublicKey)
	ctx := context.Background()

	t.Run("valid token → uid", func(t *testing.T) {
		uid, err := v.Verify(ctx, mintRS256(t, key, testKID, goodClaims()))
		if err != nil || uid != "uid-abc" {
			t.Fatalf("got uid=%q err=%v; want uid-abc, nil", uid, err)
		}
	})

	reject := func(name string, mutate func(jwt.MapClaims), signKey *rsa.PrivateKey, kid string) {
		t.Run(name, func(t *testing.T) {
			c := goodClaims()
			mutate(c)
			if _, err := v.Verify(ctx, mintRS256(t, signKey, kid, c)); err == nil {
				t.Fatalf("%s: expected rejection, got nil", name)
			}
		})
	}
	reject("wrong audience (another project)", func(c jwt.MapClaims) { c["aud"] = "someone-else" }, key, testKID)
	reject("wrong issuer", func(c jwt.MapClaims) { c["iss"] = "https://securetoken.google.com/evil" }, key, testKID)
	reject("expired", func(c jwt.MapClaims) { c["exp"] = time.Now().Add(-time.Hour).Unix() }, key, testKID)
	reject("iat in the future", func(c jwt.MapClaims) { c["iat"] = time.Now().Add(time.Hour).Unix() }, key, testKID)
	reject("missing exp", func(c jwt.MapClaims) { delete(c, "exp") }, key, testKID)
	reject("empty subject", func(c jwt.MapClaims) { c["sub"] = "" }, key, testKID)
	reject("unknown kid", func(c jwt.MapClaims) {}, key, "no-such-kid")

	// Signature forged with a DIFFERENT key but the trusted kid → rejected.
	otherKey, _ := genKeyCert(t)
	reject("signature from wrong key", func(c jwt.MapClaims) {}, otherKey, testKID)

	// Algorithm substitution: an HS256 token must be rejected by WithValidMethods.
	t.Run("alg substitution HS256", func(t *testing.T) {
		hs := jwt.NewWithClaims(jwt.SigningMethodHS256, goodClaims())
		hs.Header["kid"] = testKID
		s, err := hs.SignedString([]byte("secret"))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := v.Verify(ctx, s); err == nil {
			t.Fatal("HS256 token accepted — alg substitution not blocked")
		}
	})
}

// TestCertCacheFetchAndVerify exercises the REAL fetch → parse → verify path
// against a local server that mimics Google's x509 endpoint (kid → PEM cert),
// including the Cache-Control max-age lifetime.
func TestCertCacheFetchAndVerify(t *testing.T) {
	key, certPEM := genKeyCert(t)
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Cache-Control", "public, max-age=3600, must-revalidate")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"` + testKID + `":` + jsonString(certPEM) + `}`))
	}))
	defer srv.Close()

	v := &firebaseVerifier{
		projectID: testProject,
		iss:       testIss,
		keys:      newCertCache(srv.URL, srv.Client()),
	}
	uid, err := v.Verify(context.Background(), mintRS256(t, key, testKID, goodClaims()))
	if err != nil || uid != "uid-abc" {
		t.Fatalf("fetch+verify: uid=%q err=%v", uid, err)
	}
	// A second verify must reuse the cache (fresh for 3600s), not refetch.
	if _, err := v.Verify(context.Background(), mintRS256(t, key, testKID, goodClaims())); err != nil {
		t.Fatalf("second verify: %v", err)
	}
	if hits != 1 {
		t.Errorf("cert endpoint hit %d times; want 1 (cache should serve the second verify)", hits)
	}
	if got := v.keys.expiry.Sub(time.Now()); got < 59*time.Minute || got > 61*time.Minute {
		t.Errorf("cache expiry ~%v; want ~1h from max-age=3600", got)
	}
}

// jsonString quotes s as a JSON string literal (small helper to embed the PEM
// — which contains newlines — into the fake endpoint body).
func jsonString(s string) string {
	b := make([]byte, 0, len(s)+2)
	b = append(b, '"')
	for _, r := range s {
		switch r {
		case '"':
			b = append(b, '\\', '"')
		case '\\':
			b = append(b, '\\', '\\')
		case '\n':
			b = append(b, '\\', 'n')
		case '\r':
			b = append(b, '\\', 'r')
		case '\t':
			b = append(b, '\\', 't')
		default:
			b = append(b, string(r)...)
		}
	}
	b = append(b, '"')
	return string(b)
}

// ── resolver (uid → tenant) unit tests ─────────────────────────────────────

type funcVerifier func(context.Context, string) (string, error)

func (f funcVerifier) Verify(ctx context.Context, tok string) (string, error) { return f(ctx, tok) }

// TestBearerAuthResolveDerivesTenantFromUID proves resolve() derives the tenant
// from the VERIFIED uid (not the raw token), caches positively, and propagates
// both verify and lookup failures fail-closed.
func TestBearerAuthResolveDerivesTenantFromUID(t *testing.T) {
	ctx := context.Background()

	t.Run("uid drives tenant + positive cache", func(t *testing.T) {
		var lookups int
		a := &firebaseBearerAuth{
			verify: funcVerifier(func(_ context.Context, _ string) (string, error) { return "uid-42", nil }),
			lookup: func(_ context.Context, uid string) (int, error) {
				lookups++
				if uid != "uid-42" {
					t.Fatalf("lookup got uid=%q; tenant must come from the verified uid", uid)
				}
				return 42, nil
			},
			ttl:   time.Minute,
			cache: map[string]cacheEntry{},
		}
		for i := 0; i < 3; i++ {
			cid, err := a.resolve(ctx, "any-token")
			if err != nil || cid != 42 {
				t.Fatalf("resolve #%d: cid=%d err=%v; want 42,nil", i, cid, err)
			}
		}
		if lookups != 1 {
			t.Errorf("DB lookup ran %d times; want 1 (positive cache)", lookups)
		}
	})

	t.Run("verify error → fail closed, no lookup", func(t *testing.T) {
		a := &firebaseBearerAuth{
			verify: funcVerifier(func(_ context.Context, _ string) (string, error) { return "", errEmptySubject }),
			lookup: func(context.Context, string) (int, error) {
				t.Fatal("lookup must not run when verify fails")
				return 0, nil
			},
			ttl:   time.Minute,
			cache: map[string]cacheEntry{},
		}
		if _, err := a.resolve(ctx, "bad"); err == nil {
			t.Fatal("expected error on verify failure")
		}
	})

	t.Run("unknown uid → errUnknownUID", func(t *testing.T) {
		a := &firebaseBearerAuth{
			verify: funcVerifier(func(_ context.Context, _ string) (string, error) { return "ghost", nil }),
			lookup: func(context.Context, string) (int, error) { return 0, errUnknownUID },
			ttl:    time.Minute,
			cache:  map[string]cacheEntry{},
		}
		if _, err := a.resolve(ctx, "tok"); err != errUnknownUID {
			t.Fatalf("got err=%v; want errUnknownUID", err)
		}
	})
}

func TestBearerTokenExtraction(t *testing.T) {
	cases := []struct {
		authz  string
		want   string
		wantOK bool
	}{
		{"Bearer abc.def.ghi", "abc.def.ghi", true},
		{"bearer abc", "abc", true},
		{"BEARER abc", "abc", true},
		{"Bearer   spaced  ", "spaced", true},
		{"", "", false},
		{"Basic abc", "", false},
		{"Bearer", "", false},
		{"Bearer ", "", false},
	}
	for _, c := range cases {
		r := httptest.NewRequest("GET", "/", nil)
		if c.authz != "" {
			r.Header.Set("Authorization", c.authz)
		}
		got, err := bearerToken(r)
		if (err == nil) != c.wantOK || got != c.want {
			t.Errorf("bearerToken(%q) = %q, err=%v; want %q, ok=%v", c.authz, got, err, c.want, c.wantOK)
		}
	}
}

func TestCacheMaxAge(t *testing.T) {
	cases := []struct {
		cc   string
		want time.Duration
	}{
		{"public, max-age=3600, must-revalidate", 3600 * time.Second},
		{"max-age=19008", 19008 * time.Second},
		{"no-cache", time.Hour},    // fallback
		{"", time.Hour},            // fallback
		{"max-age=0", time.Hour},   // 0 → fallback (never pin forever)
		{"max-age=abc", time.Hour}, // unparseable → fallback
	}
	for _, c := range cases {
		if got := cacheMaxAge(c.cc); got != c.want {
			t.Errorf("cacheMaxAge(%q) = %v; want %v", c.cc, got, c.want)
		}
	}
}

// TestUsersEnterpriseSQLIsHardened locks in the DBA-confirmed guards so a
// future edit can't silently drop them: the query filters active users and
// non-null enterprise, and never selects the api_key/secret.
func TestUsersEnterpriseSQLIsHardened(t *testing.T) {
	sql := usersEnterpriseSQL
	for _, must := range []string{"id_user_firebase = $1", "active = true", "id_enterprise IS NOT NULL"} {
		if !contains(sql, must) {
			t.Errorf("usersEnterpriseSQL missing guard %q:\n%s", must, sql)
		}
	}
	if contains(sql, "api_key") {
		t.Errorf("usersEnterpriseSQL must never touch api_key:\n%s", sql)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
