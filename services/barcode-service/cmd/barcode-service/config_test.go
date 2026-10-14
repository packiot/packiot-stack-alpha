package main

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
)

// unsetenv removes k for the duration of the test (t.Setenv can only set).
func unsetenv(t *testing.T, k string) {
	t.Helper()
	t.Setenv(k, "") // registers restore of the original value
	if err := os.Unsetenv(k); err != nil {
		t.Fatal(err)
	}
}

// TestFirebaseProjectEnv pins the three states of FIREBASE_PROJECT_ID. The
// empty case is the regression: staging sets "" to retire Firebase (#159), and
// getenv used to map it back to the default, leaving the Firebase path live.
func TestFirebaseProjectEnv(t *testing.T) {
	t.Run("unset keeps the default", func(t *testing.T) {
		unsetenv(t, "FIREBASE_PROJECT_ID")
		if got := loadConfig().firebaseProject; got != defaultFirebaseProject {
			t.Fatalf("firebaseProject = %q, want %q", got, defaultFirebaseProject)
		}
	})
	t.Run("explicit empty disables", func(t *testing.T) {
		t.Setenv("FIREBASE_PROJECT_ID", "")
		if got := loadConfig().firebaseProject; got != "" {
			t.Fatalf("firebaseProject = %q, want empty", got)
		}
	})
	t.Run("explicit value wins", func(t *testing.T) {
		t.Setenv("FIREBASE_PROJECT_ID", "other-project")
		if got := loadConfig().firebaseProject; got != "other-project" {
			t.Fatalf("firebaseProject = %q, want %q", got, "other-project")
		}
	})
}

// TestEmptyFirebaseProjectRegistersNoFirebaseVerifier checks the property that
// matters end to end: with FIREBASE_PROJECT_ID="" no Firebase-issued token can
// be verified, because no Firebase verifier exists.
func TestEmptyFirebaseProjectRegistersNoFirebaseVerifier(t *testing.T) {
	t.Setenv("FIREBASE_PROJECT_ID", "")
	t.Setenv("COGNITO_ISSUER", "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_test")
	a := newAuthenticator(loadConfig(), nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	firebaseIss := "https://securetoken.google.com/" + defaultFirebaseProject
	for _, v := range a.verifiers {
		if v.issuerMatches(firebaseIss) {
			t.Fatalf("a verifier accepts Firebase issuer %q; Firebase must be off", firebaseIss)
		}
	}
	if len(a.verifiers) != 1 {
		t.Fatalf("got %d verifiers, want 1 (Cognito only)", len(a.verifiers))
	}
}

// TestLoadDBCreds pins where the DB login comes from: the secret on staging, DB_* env only with
// CREDS_SOURCE=env, and never a silent fall back when PG_SECRET_ID is missing.
func TestLoadDBCreds(t *testing.T) {
	ctx := context.Background()
	secret := func(m map[string]any) secretFetcher {
		return func(_ context.Context, _, id string) (map[string]any, error) {
			if id != "packiot/staging/barcode-service-db-creds" {
				t.Fatalf("fetched %q", id)
			}
			return m, nil
		}
	}
	noFetch := func(context.Context, string, string) (map[string]any, error) {
		t.Fatal("Secrets Manager must not be called")
		return nil, nil
	}

	t.Run("secret", func(t *testing.T) {
		unsetenv(t, "CREDS_SOURCE")
		t.Setenv("PG_SECRET_ID", "packiot/staging/barcode-service-db-creds")
		c, err := loadDBCreds(ctx, secret(map[string]any{"host": "pgbouncer", "port": float64(5432),
			"user": "barcode_service", "password": "p@ss:w/rd", "name": "packiot_analytics"}))
		if err != nil {
			t.Fatal(err)
		}
		if c.User != "barcode_service" || c.Port != 5432 || c.Host != "pgbouncer" {
			t.Fatalf("got %+v", c)
		}
		if strings.Contains(c.Redacted("x"), "p@ss") {
			t.Fatal("Redacted leaks the password")
		}
	})
	t.Run("secret missing a field", func(t *testing.T) {
		unsetenv(t, "CREDS_SOURCE")
		t.Setenv("PG_SECRET_ID", "packiot/staging/barcode-service-db-creds")
		if _, err := loadDBCreds(ctx, secret(map[string]any{"host": "h", "port": "5432", "user": "u",
			"name": "d"})); err == nil {
			t.Fatal("want an error for a secret without a password")
		}
	})
	t.Run("no PG_SECRET_ID fails closed", func(t *testing.T) {
		unsetenv(t, "CREDS_SOURCE")
		unsetenv(t, "PG_SECRET_ID")
		t.Setenv("DB_USER", "postgres") // a stale admin env must not be picked up
		t.Setenv("DB_PASSWORD", "admin")
		if _, err := loadDBCreds(ctx, noFetch); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("CREDS_SOURCE=env", func(t *testing.T) {
		t.Setenv("CREDS_SOURCE", "env")
		unsetenv(t, "DB_USER")
		t.Setenv("DB_PASSWORD", "dev")
		c, err := loadDBCreds(ctx, noFetch)
		if err != nil {
			t.Fatal(err)
		}
		if c.User != dbRole {
			t.Fatalf("default DB_USER = %q, want %q", c.User, dbRole)
		}
	})
	t.Run("CREDS_SOURCE=env without a password", func(t *testing.T) {
		t.Setenv("CREDS_SOURCE", "env")
		unsetenv(t, "DB_PASSWORD")
		if _, err := loadDBCreds(ctx, noFetch); err == nil {
			t.Fatal("want an error")
		}
	})
}
