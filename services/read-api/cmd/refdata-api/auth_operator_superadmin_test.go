package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

const testJWTSecret = "test-secret"

// mintOperatorToken forges an HS256 operator JWT the way edge-api's LoginService
// does (payload carries `user`), signed with the given secret.
func mintOperatorToken(t *testing.T, user, secret string) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"user": user})
	s, err := tok.SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return s
}

// escalator builds an operatorSuperAdminAuth with INJECTED DB checks (no pool),
// so the tenant-authority logic is tested without a database.
func escalator(allow []string, superUsers map[string]bool, activeEnts map[int]bool) *operatorSuperAdminAuth {
	al := map[string]bool{}
	for _, e := range allow {
		al[e] = true
	}
	return &operatorSuperAdminAuth{
		secret:             []byte(testJWTSecret),
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
	t.Setenv("JWT_SECRET", "whatever")
	if a := newOperatorSuperAdminAuth(nil, discardLogger()); a != nil {
		t.Fatal("flag off → must be nil (dark)")
	}
	// Flag on but no secret → still dark (can't verify tokens).
	t.Setenv("OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED", "true")
	t.Setenv("JWT_SECRET", "")
	if a := newOperatorSuperAdminAuth(nil, discardLogger()); a != nil {
		t.Fatal("flag on but no JWT_SECRET → must be nil (dark)")
	}
}
