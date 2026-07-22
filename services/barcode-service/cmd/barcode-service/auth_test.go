package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestBearerToken(t *testing.T) {
	cases := []struct {
		hdr     string
		want    string
		wantErr bool
	}{
		{"Bearer abc.def.ghi", "abc.def.ghi", false},
		{"bearer abc", "abc", false}, // case-insensitive scheme
		{"Basic abc", "", true},
		{"", "", true},
		{"Bearer ", "", true},
	}
	for _, c := range cases {
		r, _ := http.NewRequest("GET", "/", nil)
		if c.hdr != "" {
			r.Header.Set("Authorization", c.hdr)
		}
		got, err := bearerToken(r)
		if c.wantErr {
			if err == nil {
				t.Errorf("hdr=%q: want error, got %q", c.hdr, got)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("hdr=%q: got (%q,%v), want %q", c.hdr, got, err, c.want)
		}
	}
}

func TestEnterpriseFromClaims(t *testing.T) {
	cases := []struct {
		name    string
		claims  jwt.MapClaims
		want    int
		wantErr bool
	}{
		{"string", jwt.MapClaims{"custom:id_enterprise": "42"}, 42, false},
		{"number", jwt.MapClaims{"custom:id_enterprise": float64(9)}, 9, false},
		{"missing", jwt.MapClaims{}, 0, true},
		{"zero", jwt.MapClaims{"custom:id_enterprise": "0"}, 0, true},
		{"negative", jwt.MapClaims{"custom:id_enterprise": float64(-3)}, 0, true},
		{"garbage", jwt.MapClaims{"custom:id_enterprise": "abc"}, 0, true},
	}
	for _, c := range cases {
		got, err := enterpriseFromClaims(c.claims)
		if c.wantErr && err == nil {
			t.Errorf("%s: want error, got %d", c.name, got)
		}
		if !c.wantErr && (err != nil || got != c.want) {
			t.Errorf("%s: got (%d,%v), want %d", c.name, got, err, c.want)
		}
	}
}

// fakeVerifier is a stand-in issuerVerifier for routing/fail-closed tests.
type fakeVerifier struct {
	iss string
	id  Identity
	err error
}

func (f fakeVerifier) issuerMatches(iss string) bool { return iss == f.iss }
func (f fakeVerifier) authenticate(_ context.Context, _ string) (Identity, error) {
	return f.id, f.err
}

// mintToken signs a token with `claims` under kid for the given key.
func mintToken(t *testing.T, key *rsa.PrivateKey, kid string, claims jwt.Claims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return s
}

// TestAuthenticator_RoutesByIssuer proves the issuer-agnostic dispatch: a token
// is routed to the verifier that owns its `iss`, and an unknown issuer is a
// fail-closed rejection.
func TestAuthenticator_RoutesByIssuer(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	a := &authenticator{
		logger: slog.Default(),
		verifiers: []issuerVerifier{
			fakeVerifier{iss: "iss-A", id: Identity{EnterpriseID: 11}},
			fakeVerifier{iss: "iss-B", id: Identity{EnterpriseID: 22}},
		},
	}

	// routes to A
	tokA := mintToken(t, key, "k", jwt.RegisteredClaims{Issuer: "iss-A"})
	id, err := a.resolve(context.Background(), tokA)
	if err != nil || id.EnterpriseID != 11 {
		t.Fatalf("iss-A: got (%+v,%v), want enterprise 11", id, err)
	}

	// routes to B
	tokB := mintToken(t, key, "k", jwt.RegisteredClaims{Issuer: "iss-B"})
	id, err = a.resolve(context.Background(), tokB)
	if err != nil || id.EnterpriseID != 22 {
		t.Fatalf("iss-B: got (%+v,%v), want enterprise 22", id, err)
	}

	// unknown issuer → fail closed
	tokC := mintToken(t, key, "k", jwt.RegisteredClaims{Issuer: "iss-unknown"})
	if _, err := a.resolve(context.Background(), tokC); !errors.Is(err, errUnknownIssuer) {
		t.Fatalf("unknown issuer: err=%v, want errUnknownIssuer", err)
	}
}

// TestAuthenticator_RejectsNonPositiveTenant is defence-in-depth: even a
// "successful" verify that yields id_enterprise ≤ 0 must be rejected.
func TestAuthenticator_RejectsNonPositiveTenant(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	a := &authenticator{
		logger:    slog.Default(),
		verifiers: []issuerVerifier{fakeVerifier{iss: "iss-Z", id: Identity{EnterpriseID: 0}}},
	}
	tok := mintToken(t, key, "k", jwt.RegisteredClaims{Issuer: "iss-Z"})
	if _, err := a.resolve(context.Background(), tok); !errors.Is(err, errUnknownTenant) {
		t.Fatalf("zero tenant: err=%v, want errUnknownTenant", err)
	}
}

// TestFirebaseVerifier_FullVerify exercises the REAL Firebase verify path
// end-to-end offline: a self-signed RSA key stands in for Google's cert, and a
// fake lookup stands in for the users table. It proves signature + iss + aud +
// exp are all enforced and the tenant is derived from the verified uid.
func TestFirebaseVerifier_FullVerify(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const project, uid = "fbtest", "uid-123"

	v := newFirebaseVerifier(project, func(_ context.Context, gotUID string) (int, error) {
		if gotUID != uid {
			return 0, errUnknownUID
		}
		return 99, nil
	}, nil)
	// Inject the public key into the cache so no network fetch happens.
	v.keys.mu.Lock()
	v.keys.keys = map[string]*rsa.PublicKey{"kid1": &key.PublicKey}
	v.keys.expiry = time.Now().Add(time.Hour)
	v.keys.mu.Unlock()

	valid := mintToken(t, key, "kid1", jwt.RegisteredClaims{
		Issuer:    "https://securetoken.google.com/" + project,
		Audience:  jwt.ClaimStrings{project},
		Subject:   uid,
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt:  jwt.NewNumericDate(time.Now()),
	})
	id, err := v.authenticate(context.Background(), valid)
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if id.EnterpriseID != 99 || id.Subject != uid {
		t.Fatalf("identity = %+v, want enterprise 99 uid %q", id, uid)
	}

	// wrong audience → rejected
	badAud := mintToken(t, key, "kid1", jwt.RegisteredClaims{
		Issuer:    "https://securetoken.google.com/" + project,
		Audience:  jwt.ClaimStrings{"someone-else"},
		Subject:   uid,
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt:  jwt.NewNumericDate(time.Now()),
	})
	if _, err := v.authenticate(context.Background(), badAud); err == nil {
		t.Fatalf("token with wrong audience was accepted")
	}

	// expired → rejected
	expired := mintToken(t, key, "kid1", jwt.RegisteredClaims{
		Issuer:    "https://securetoken.google.com/" + project,
		Audience:  jwt.ClaimStrings{project},
		Subject:   uid,
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(-time.Hour)),
		IssuedAt:  jwt.NewNumericDate(time.Now().Add(-2 * time.Hour)),
	})
	if _, err := v.authenticate(context.Background(), expired); err == nil {
		t.Fatalf("expired token was accepted")
	}
}

// TestCognitoVerifier_ClaimTenant proves the Cognito path derives the tenant
// from the signed custom:id_enterprise claim, offline.
func TestCognitoVerifier_ClaimTenant(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	const iss = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_TESTPOOL"

	v := newCognitoVerifier(iss, "client-abc", nil)
	v.keys.mu.Lock()
	v.keys.keys = map[string]*rsa.PublicKey{"ck1": &key.PublicKey}
	v.keys.expiry = time.Now().Add(time.Hour)
	v.keys.mu.Unlock()

	claims := jwt.MapClaims{
		"iss":                  iss,
		"aud":                  "client-abc",
		"sub":                  "user-xyz",
		"custom:id_enterprise": "4",
		"exp":                  time.Now().Add(time.Hour).Unix(),
		"iat":                  time.Now().Unix(),
	}
	tok := mintToken(t, key, "ck1", claims)
	id, err := v.authenticate(context.Background(), tok)
	if err != nil {
		t.Fatalf("valid cognito token rejected: %v", err)
	}
	if id.EnterpriseID != 4 {
		t.Fatalf("enterprise = %d, want 4 (from custom:id_enterprise)", id.EnterpriseID)
	}

	// no tenant claim → rejected
	noEnt := mintToken(t, key, "ck1", jwt.MapClaims{
		"iss": iss, "aud": "client-abc", "sub": "u",
		"exp": time.Now().Add(time.Hour).Unix(), "iat": time.Now().Unix(),
	})
	if _, err := v.authenticate(context.Background(), noEnt); err == nil {
		t.Fatalf("token without custom:id_enterprise was accepted")
	}
}
