package main

import (
	"context"
	"errors"
	"sync"
	"testing"
)

func stubDBSecret(t *testing.T, dsn string, err error) *int {
	t.Helper()
	calls := 0
	orig := fetchDBDSN
	fetchDBDSN = func(_ context.Context, _, _, _ string) (string, error) {
		calls++
		return dsn, err
	}
	reset := func() { secretDSNOnce = sync.Once{}; secretDSN, secretDSNErr = "", nil }
	reset()
	t.Cleanup(func() { fetchDBDSN = orig; reset() })
	return &calls
}

func TestRegisterDSN_SecretUsedAndFetchedOnce(t *testing.T) {
	calls := stubDBSecret(t, "postgres://sparkplug_agent:x@db:5432/packiot", nil)
	t.Setenv("AGENT_REGISTER_DSN", "")
	t.Setenv("AGENT_DB_SECRET_ID", "packiot/production/sparkplug-agent-db-creds")
	t.Setenv("DB_USER", "postgres") // must NOT win over the secret
	t.Setenv("DB_PASSWORD", "superuser")
	for i := 0; i < 3; i++ { // link health + derive rules + capture each ask at boot
		dsn, err := registerDSN()
		if err != nil || dsn != "postgres://sparkplug_agent:x@db:5432/packiot" {
			t.Fatalf("registerDSN = %q, %v", dsn, err)
		}
	}
	if *calls != 1 {
		t.Fatalf("secret fetched %d times, want 1", *calls)
	}
}

func TestRegisterDSN_SecretErrorDoesNotFallBackToDBVars(t *testing.T) {
	stubDBSecret(t, "", errors.New("AccessDenied"))
	t.Setenv("AGENT_REGISTER_DSN", "")
	t.Setenv("AGENT_DB_SECRET_ID", "packiot/production/sparkplug-agent-db-creds")
	t.Setenv("DB_USER", "postgres")
	t.Setenv("DB_PASSWORD", "superuser")
	if dsn, err := registerDSN(); err == nil {
		t.Fatalf("want the fetch error, got dsn %q", dsn)
	}
}

func TestRegisterDSN_ExplicitDSNWinsAndSkipsSecret(t *testing.T) {
	calls := stubDBSecret(t, "postgres://from-secret", nil)
	t.Setenv("AGENT_REGISTER_DSN", "postgres://explicit")
	t.Setenv("AGENT_DB_SECRET_ID", "some/id")
	if dsn, err := registerDSN(); err != nil || dsn != "postgres://explicit" {
		t.Fatalf("registerDSN = %q, %v", dsn, err)
	}
	if *calls != 0 {
		t.Fatalf("secret fetched %d times, want 0", *calls)
	}
}

func TestRegisterDSN_NoSecretIDKeepsDBVarsPath(t *testing.T) {
	calls := stubDBSecret(t, "postgres://from-secret", nil)
	t.Setenv("AGENT_REGISTER_DSN", "")
	t.Setenv("AGENT_DB_SECRET_ID", "")
	t.Setenv("DB_USER", "u")
	t.Setenv("DB_PASSWORD", "p")
	dsn, err := registerDSN()
	if err != nil || *calls != 0 || dsn == "postgres://from-secret" {
		t.Fatalf("registerDSN = %q, %v, calls %d", dsn, err, *calls)
	}
}
