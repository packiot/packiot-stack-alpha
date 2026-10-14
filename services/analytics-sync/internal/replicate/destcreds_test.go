package replicate

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestLoadDestCredsSecret(t *testing.T) {
	t.Setenv("CREDS_SOURCE", "")
	t.Setenv("PG_SECRET_ID", "packiot/staging/legacy-replicator-db-creds")
	var gotID string
	fetch := func(_ context.Context, _, id string) (map[string]any, error) {
		gotID = id
		return map[string]any{"host": "10.10.10.89", "port": float64(5432), "user": "legacy_replicator",
			"password": "p@ss/w:rd", "name": "packiot_analytics"}, nil
	}
	c, err := LoadDestCreds(context.Background(), &Config{}, fetch)
	if err != nil {
		t.Fatal(err)
	}
	if gotID != "packiot/staging/legacy-replicator-db-creds" || c.User != DestRole || c.Port != 5432 ||
		c.Database != "packiot_analytics" || c.Password != "p@ss/w:rd" {
		t.Fatalf("got %+v from %q", c, gotID)
	}
}

// No PG_SECRET_ID and no CREDS_SOURCE=env must fail closed — never fall back to the
// old DEST_DB_USER=postgres default or an admin secret.
func TestLoadDestCredsFailsClosed(t *testing.T) {
	t.Setenv("CREDS_SOURCE", "")
	t.Setenv("PG_SECRET_ID", "")
	called := false
	_, err := LoadDestCreds(context.Background(), &Config{DestUser: "postgres", DestPassword: "x"},
		func(context.Context, string, string) (map[string]any, error) { called = true; return nil, nil })
	if err == nil || !strings.Contains(err.Error(), "PG_SECRET_ID is empty") || called {
		t.Fatalf("err=%v called=%v; want PG_SECRET_ID is empty, no fetch", err, called)
	}
}

func TestLoadDestCredsSecretIncomplete(t *testing.T) {
	t.Setenv("CREDS_SOURCE", "")
	t.Setenv("PG_SECRET_ID", "s")
	_, err := LoadDestCreds(context.Background(), &Config{}, func(context.Context, string, string) (map[string]any, error) {
		return map[string]any{"host": "h", "port": "5432", "user": "u", "name": "d"}, nil
	})
	if err == nil || !strings.Contains(err.Error(), "all required") {
		t.Fatalf("err=%v; want missing-field error", err)
	}
	_, err = LoadDestCreds(context.Background(), &Config{}, func(context.Context, string, string) (map[string]any, error) {
		return nil, errors.New("denied")
	})
	if err == nil || err.Error() != "denied" {
		t.Fatalf("err=%v; want the fetch error", err)
	}
}

func TestLoadDestCredsEnv(t *testing.T) {
	t.Setenv("CREDS_SOURCE", "env")
	t.Setenv("PG_SECRET_ID", "")
	t.Setenv("DEST_DB_USER", "")
	t.Setenv("DEST_DB_PASSWORD", "dev")
	c, err := LoadDestCreds(context.Background(), Load(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if c.User != DestRole || c.Password != "dev" || c.Database != "packiot_analytics" {
		t.Fatalf("got %+v; want the legacy_replicator default", c)
	}
	t.Setenv("DEST_DB_PASSWORD", "")
	if _, err := LoadDestCreds(context.Background(), Load(), nil); err == nil {
		t.Fatal("CREDS_SOURCE=env with no DEST_DB_PASSWORD must fail")
	}
}
