package secrets

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// stubSM swaps the Secrets Manager seam for the duration of a test and
// records whether it was reached.
func stubSM(t *testing.T, raw map[string]any, err error) *bool {
	t.Helper()
	called := false
	orig := fetchSecretJSON
	fetchSecretJSON = func(_ context.Context, _, _ string) (map[string]any, error) {
		called = true
		return raw, err
	}
	t.Cleanup(func() { fetchSecretJSON = orig })
	return &called
}

func TestFetchAMQPCreds_EnvPath(t *testing.T) {
	called := stubSM(t, nil, errors.New("SM must not be called in env mode"))
	t.Setenv("CREDS_SOURCE", "env")
	t.Setenv("RABBITMQ_USER", "dev-user")
	t.Setenv("RABBITMQ_PASSWORD", "p@ss:w/rd")
	t.Setenv("RABBITMQ_HOST", "")
	t.Setenv("RABBITMQ_PORT", "")

	c, err := FetchAMQPCreds(context.Background(), "us-east-1", "some/secret", "rabbitmq", 5672)
	if err != nil {
		t.Fatalf("env path: unexpected error: %v", err)
	}
	if *called {
		t.Fatal("env path: Secrets Manager was called")
	}
	want := AMQPCreds{Username: "dev-user", Password: "p@ss:w/rd", Host: "rabbitmq", Port: 5672}
	if *c != want {
		t.Fatalf("env path: got %+v, want %+v", *c, want)
	}
}

func TestFetchAMQPCreds_EnvPathHostPortOverride(t *testing.T) {
	stubSM(t, nil, errors.New("SM must not be called in env mode"))
	t.Setenv("CREDS_SOURCE", "env")
	t.Setenv("RABBITMQ_USER", "u")
	t.Setenv("RABBITMQ_PASSWORD", "p")
	t.Setenv("RABBITMQ_HOST", "localhost")
	t.Setenv("RABBITMQ_PORT", "15672")

	c, err := FetchAMQPCreds(context.Background(), "us-east-1", "some/secret", "rabbitmq", 5672)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.Host != "localhost" || c.Port != 15672 {
		t.Fatalf("override ignored: got %s:%d", c.Host, c.Port)
	}

	t.Setenv("RABBITMQ_PORT", "not-a-port")
	if _, err := FetchAMQPCreds(context.Background(), "us-east-1", "some/secret", "rabbitmq", 5672); err == nil ||
		!strings.Contains(err.Error(), "RABBITMQ_PORT") {
		t.Fatalf("bad port: want error naming RABBITMQ_PORT, got %v", err)
	}
}

func TestFetchAMQPCreds_EnvPathMissingVarsFailsClosed(t *testing.T) {
	cases := []struct {
		name, user, pass string
	}{
		{"both missing", "", ""},
		{"user missing", "", "p"},
		{"password missing", "u", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// A working SM stub proves we do NOT silently fall back to it.
			called := stubSM(t, map[string]any{"username": "sm", "password": "sm"}, nil)
			t.Setenv("CREDS_SOURCE", "env")
			t.Setenv("RABBITMQ_USER", tc.user)
			t.Setenv("RABBITMQ_PASSWORD", tc.pass)

			c, err := FetchAMQPCreds(context.Background(), "us-east-1", "some/secret", "rabbitmq", 5672)
			if err == nil {
				t.Fatalf("want error, got creds %+v", c)
			}
			if *called {
				t.Fatal("fell back to Secrets Manager")
			}
			for _, v := range []string{"CREDS_SOURCE=env", "RABBITMQ_USER", "RABBITMQ_PASSWORD"} {
				if !strings.Contains(err.Error(), v) {
					t.Fatalf("error %q does not name %s", err, v)
				}
			}
		})
	}
}

func TestFetchAMQPCreds_NonEnvTakesSecretsManager(t *testing.T) {
	// "" = unset-equivalent; the others prove the gate is an exact match.
	for _, src := range []string{"", "ENV", "Env", "env ", "sm", "1"} {
		t.Run("CREDS_SOURCE="+src, func(t *testing.T) {
			called := stubSM(t, map[string]any{"username": "sm-user", "password": "sm-pass"}, nil)
			t.Setenv("CREDS_SOURCE", src)
			// Env creds present: if the env path were taken we'd see them.
			t.Setenv("RABBITMQ_USER", "env-user")
			t.Setenv("RABBITMQ_PASSWORD", "env-pass")

			c, err := FetchAMQPCreds(context.Background(), "us-east-1", "some/secret", "rabbitmq", 5672)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !*called {
				t.Fatal("Secrets Manager seam not reached — env path was taken")
			}
			if c.Username != "sm-user" || c.Password != "sm-pass" {
				t.Fatalf("got %+v, want SM creds", *c)
			}
		})
	}
}

func TestFetchAMQPCreds_SMMissingFieldsStillErrors(t *testing.T) {
	stubSM(t, map[string]any{"username": "only-user"}, nil)
	t.Setenv("CREDS_SOURCE", "")
	_, err := FetchAMQPCreds(context.Background(), "us-east-1", "some/secret", "rabbitmq", 5672)
	if err == nil || !strings.Contains(err.Error(), "secret some/secret: missing username or password") {
		t.Fatalf("got %v", err)
	}
}
