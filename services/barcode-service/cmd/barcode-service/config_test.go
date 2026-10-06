package main

import (
	"io"
	"log/slog"
	"os"
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
