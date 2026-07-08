package erpconnector

import (
	"context"
	"strings"
	"testing"
)

func TestRequireSecretRef(t *testing.T) {
	tests := []struct {
		name    string
		val     string
		wantErr bool
	}{
		{"valid secret ref", "secret://incoplast/erp/dsn", false},
		{"empty is rejected", "", true},
		{"literal dsn rejected", "user=scott;password=tiger;host=erp", true},
		{"oracle easy-connect literal rejected", "scott/tiger@//erp.local:1521/ORCL", true},
		{"almost-scheme rejected", "secret:/incoplast/dsn", true},
		{"http ref rejected", "https://vault/erp/dsn", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := RequireSecretRef("dsn_ref", tt.val)
			if tt.wantErr && err == nil {
				t.Fatalf("RequireSecretRef(%q): want error, got nil", tt.val)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("RequireSecretRef(%q): unexpected error: %v", tt.val, err)
			}
		})
	}
}

func TestRequireSecretRefDoesNotLeakValue(t *testing.T) {
	// A rejected literal must not be echoed verbatim into the error — an
	// operator sees which field is wrong, not the credential.
	secret := "password=SuperSecretHunter2"
	err := RequireSecretRef("dsn_ref", secret)
	if err == nil {
		t.Fatal("expected error for literal value")
	}
	if strings.Contains(err.Error(), "SuperSecretHunter2") {
		t.Fatalf("error leaked the secret value: %v", err)
	}
}

func TestEnvSecretResolver(t *testing.T) {
	// secret://incoplast/erp/dsn → ERP_SECRET_INCOPLAST_ERP_DSN
	t.Setenv("ERP_SECRET_INCOPLAST_ERP_DSN", "/data/erp.db")
	r := EnvSecretResolver{}

	got, err := r.Resolve(context.Background(), "secret://incoplast/erp/dsn")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got != "/data/erp.db" {
		t.Fatalf("Resolve = %q, want /data/erp.db", got)
	}

	// A non-secret ref must be refused even by the resolver.
	if _, err := r.Resolve(context.Background(), "user=scott;password=tiger"); err == nil {
		t.Fatal("Resolve of a literal value: want error, got nil")
	}

	// An unset secret is a loud error, not an empty DSN.
	if _, err := r.Resolve(context.Background(), "secret://missing/one"); err == nil {
		t.Fatal("Resolve of unset secret: want error, got nil")
	}
}

func TestEnvVarName(t *testing.T) {
	r := EnvSecretResolver{}
	tests := map[string]string{
		"secret://incoplast/erp/dsn": "ERP_SECRET_INCOPLAST_ERP_DSN",
		"secret://a.b-c/d":           "ERP_SECRET_A_B_C_D",
		"secret://x//y":              "ERP_SECRET_X_Y",
	}
	for ref, want := range tests {
		if got := r.envVarName(ref); got != want {
			t.Errorf("envVarName(%q) = %q, want %q", ref, got, want)
		}
	}
}

func TestStaticResolver(t *testing.T) {
	r := StaticResolver{"secret://t/dsn": "/tmp/x.db"}
	got, err := r.Resolve(context.Background(), "secret://t/dsn")
	if err != nil || got != "/tmp/x.db" {
		t.Fatalf("Resolve = %q, %v", got, err)
	}
	// Still enforces the scheme — a mock must not become a cleartext bypass.
	if _, err := r.Resolve(context.Background(), "literal-dsn"); err == nil {
		t.Fatal("StaticResolver of a literal: want error, got nil")
	}
}
