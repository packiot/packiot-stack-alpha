package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testJWTSecret = "test-secret"

// fakeCognito stands in for the read-api Cognito verifier. It decodes a test
// "token" of the form "valid:<email>" (verified) or "unverified:<email>"
// (email_verified=false); anything else fails verification. This lets the
// escalation's tenant-authority logic be tested without JWKS/network — the same
// contract as the real *cognitoVerifier.VerifyClaims.
type fakeCognito struct{}

func (fakeCognito) VerifyClaims(_ context.Context, token string) (verifiedClaims, error) {
	if e := strings.TrimPrefix(token, "valid:"); e != token {
		return verifiedClaims{uid: "sub-" + e, email: strings.ToLower(e), emailVerified: true}, nil
	}
	if e := strings.TrimPrefix(token, "unverified:"); e != token {
		return verifiedClaims{uid: "sub-" + e, email: strings.ToLower(e), emailVerified: false}, nil
	}
	return verifiedClaims{}, errors.New("invalid token")
}

// mintOperatorToken returns a fake Cognito ID token for `user`. A non-default
// secret simulates a forged/invalid token that VerifyClaims rejects — preserving
// the "forged signature" fail-closed case from the HS256 era.
func mintOperatorToken(t *testing.T, user, secret string) string {
	t.Helper()
	if secret != testJWTSecret {
		return "forged:" + user // no valid:/unverified: prefix → fakeCognito errors
	}
	return "valid:" + user
}

// escalator builds an operatorSuperAdminAuth with INJECTED DB checks (no pool)
// and the fake Cognito verifier, so the tenant-authority logic is tested without
// a database or JWKS.
func escalator(allow []string, superUsers map[string]bool, activeEnts map[int]bool) *operatorSuperAdminAuth {
	al := map[string]bool{}
	for _, e := range allow {
		al[e] = true
	}
	return &operatorSuperAdminAuth{
		cognito:            fakeCognito{},
		allowlist:          al,
		isLiveSuperUser:    func(_ context.Context, u string) bool { return superUsers[u] },
		isEnterpriseActive: func(_ context.Context, id int) bool { return activeEnts[id] },
	}
}

func reqWith(token string, idEnterprise string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/v1/operator-po-list?idEnterprise="+idEnterprise, nil)
	if token != "" {
		r.Header.Set("x-operator-superadmin-token", token)
	}
	return r
}

func TestResolveTarget_GrantsVerifiedSuperAdminCrossTenant(t *testing.T) {
	a := escalator(
		[]string{"dev@packiot.com"},
		map[string]bool{"dev@packiot.com": true},
		map[int]bool{9: true},
	)
	tok := mintOperatorToken(t, "dev@packiot.com", testJWTSecret)
	got, ok := a.resolveTarget(context.Background(), reqWith(tok, "9"), 3 /*home*/)
	if !ok || got != 9 {
		t.Fatalf("want (9,true), got (%d,%v)", got, ok)
	}
}

func TestResolveTarget_FailClosedToHome(t *testing.T) {
	base := escalator(
		[]string{"dev@packiot.com"},
		map[string]bool{"dev@packiot.com": true},
		map[int]bool{9: true},
	)
	good := mintOperatorToken(t, "dev@packiot.com", testJWTSecret)

	cases := []struct {
		name string
		a    *operatorSuperAdminAuth
		req  *http.Request
	}{
		{"no token header", base, reqWith("", "9")},
		{"no idEnterprise", base, reqWith(good, "")},
		{"target == home (no cross-tenant intent)", base, func() *http.Request { return reqWith(good, "3") }()},
		{"forged signature (wrong secret)", base, reqWith(mintOperatorToken(t, "dev@packiot.com", "WRONG"), "9")},
		{"garbage token", base, reqWith("not-a-jwt", "9")},
		{"user not on allowlist", base, reqWith(mintOperatorToken(t, "rogue@evil.com", testJWTSecret), "9")},
		{
			"allowlisted but DB super_user=false",
			escalator([]string{"dev@packiot.com"}, map[string]bool{}, map[int]bool{9: true}),
			reqWith(good, "9"),
		},
		{
			"target enterprise inactive",
			escalator([]string{"dev@packiot.com"}, map[string]bool{"dev@packiot.com": true}, map[int]bool{}),
			reqWith(good, "9"),
		},
		{"negative target", base, reqWith(good, "-1")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := tc.a.resolveTarget(context.Background(), tc.req, 3 /*home*/)
			if ok || got != 0 {
				t.Fatalf("want fail-closed (0,false), got (%d,%v)", got, ok)
			}
		})
	}
}

func TestParseSuperAdminAllowlist_DefaultsAndNormalizes(t *testing.T) {
	// empty → default dev@packiot.com
	if al := parseSuperAdminAllowlist(""); !al["dev@packiot.com"] || len(al) != 1 {
		t.Fatalf("empty should default to dev@packiot.com, got %v", al)
	}
	if al := parseSuperAdminAllowlist("   "); !al["dev@packiot.com"] {
		t.Fatalf("whitespace should default, got %v", al)
	}
	// comma list, trimmed + lowercased
	al := parseSuperAdminAllowlist("dev@packiot.com, SRE@Packiot.com")
	if !al["dev@packiot.com"] || !al["sre@packiot.com"] || al["someone@else.com"] {
		t.Fatalf("unexpected allowlist %v", al)
	}
}

func TestNewOperatorSuperAdminAuth_DarkByDefault(t *testing.T) {
	t.Setenv("OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED", "false")
	if a := newOperatorSuperAdminAuth(nil, discardLogger(), fakeCognito{}); a != nil {
		t.Fatal("flag off → must be nil (dark)")
	}
	// Flag on but no Cognito verifier → still dark (can't verify tokens).
	t.Setenv("OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED", "true")
	if a := newOperatorSuperAdminAuth(nil, discardLogger(), nil); a != nil {
		t.Fatal("flag on but no Cognito verifier → must be nil (dark)")
	}
}
