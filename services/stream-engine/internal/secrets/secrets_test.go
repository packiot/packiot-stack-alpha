package secrets

import (
	"context"
	"strings"
	"testing"
)

// TestAMQPCredsSource pins the precedence that keeps staging off the broker
// admin: AMQP_CREDS_SOURCE wins over CREDS_SOURCE, and only the literal "env"
// selects env vars.
func TestAMQPCredsSource(t *testing.T) {
	cases := []struct {
		name, credsSource, amqpSource string
		wantEnv                       bool
	}{
		{"neither set: Secrets Manager", "", "", false},
		{"dev: CREDS_SOURCE=env only", "env", "", true},
		{"staging: DB from env, AMQP pinned to Secrets Manager", "env", "aws", false},
		{"AMQP env while DB uses Secrets Manager", "", "env", true},
		{"typo falls to Secrets Manager", "env", "Env", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("CREDS_SOURCE", tc.credsSource)
			t.Setenv(amqpCredsSourceVar, tc.amqpSource)
			if got := amqpCredsFromEnv(); got != tc.wantEnv {
				t.Fatalf("amqpCredsFromEnv() = %v, want %v", got, tc.wantEnv)
			}
		})
	}
}

// TestFetchAMQPCredsEnvPath: with AMQP_CREDS_SOURCE=env the env vars are used
// and no Secrets Manager call is made (an unreachable secret id would fail).
func TestFetchAMQPCredsEnvPath(t *testing.T) {
	t.Setenv("CREDS_SOURCE", "")
	t.Setenv(amqpCredsSourceVar, "env")
	t.Setenv("RABBITMQ_USER", "stream-engine")
	t.Setenv("RABBITMQ_PASSWORD", "x")
	t.Setenv("RABBITMQ_HOST", "")
	t.Setenv("RABBITMQ_PORT", "")
	c, err := FetchAMQPCreds(t.Context(), "us-east-1", "does-not-exist", "rabbitmq", 5672)
	if err != nil {
		t.Fatal(err)
	}
	if c.Username != "stream-engine" || c.Host != "rabbitmq" || c.Port != 5672 {
		t.Fatalf("unexpected creds %+v", *c)
	}
}

// An unset PG_SECRET_ID is a boot error, never a fall back to the admin secret (the config default
// used to be packiot/staging/db). Fails before any AWS call.
func TestFetchDBCredsEmptySecretIDFailsClosed(t *testing.T) {
	t.Setenv("CREDS_SOURCE", "")
	if _, err := FetchDBCreds(context.Background(), "us-east-1", ""); err == nil ||
		!strings.Contains(err.Error(), "PG_SECRET_ID is empty") {
		t.Fatalf("want the empty-secret error, got %v", err)
	}
}
