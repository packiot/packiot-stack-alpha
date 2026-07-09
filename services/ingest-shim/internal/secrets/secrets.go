// Package secrets fetches the RabbitMQ creds from AWS Secrets Manager at
// startup. CO-5: no plaintext RABBITMQ_PASSWORD in compose env (visible via
// `docker inspect`). This is a trimmed, AMQP-only copy of the same helper in
// services/oeecloud-worker/internal/secrets — the shim publishes as the same
// least-privilege `oeecloud-worker` broker user (secret
// packiot/staging/rabbitmq-oeecloud-creds).
//
// The CREDS_SOURCE=env fallback mirrors the worker: when set, skip the SM
// call and read RABBITMQ_USER/RABBITMQ_PASSWORD from the environment. Used
// ONLY for local dev — never in staging/prod, where plaintext passwords in
// `docker inspect` are exactly what CO-5 removes.
package secrets

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strconv"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

const credsSourceEnv = "env"

type AMQPCreds struct {
	Username string
	Password string
	Host     string
	Port     int
}

func pick(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			switch x := v.(type) {
			case string:
				if x != "" {
					return x
				}
			case float64:
				return fmt.Sprintf("%v", int64(x))
			}
		}
	}
	return ""
}

func getSecretJSON(ctx context.Context, region, secretID string) (map[string]any, error) {
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}
	sm := secretsmanager.NewFromConfig(cfg)
	out, err := sm.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: &secretID})
	if err != nil {
		return nil, fmt.Errorf("get secret %s: %w", secretID, err)
	}
	if out.SecretString == nil {
		return nil, fmt.Errorf("secret %s: no SecretString", secretID)
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(*out.SecretString), &raw); err != nil {
		return nil, fmt.Errorf("parse secret %s: %w", secretID, err)
	}
	return raw, nil
}

// FetchAMQPCreds reads {username, password} from the secret + uses
// caller-supplied host/port (docker-network constants). When
// $CREDS_SOURCE=env it reads RABBITMQ_USER/RABBITMQ_PASSWORD (and optional
// RABBITMQ_HOST/RABBITMQ_PORT overrides) from the environment instead.
func FetchAMQPCreds(ctx context.Context, region, secretID, host string, port int) (*AMQPCreds, error) {
	if os.Getenv("CREDS_SOURCE") == credsSourceEnv {
		return fetchAMQPCredsFromEnv(host, port)
	}
	raw, err := getSecretJSON(ctx, region, secretID)
	if err != nil {
		return nil, err
	}
	c := &AMQPCreds{
		Username: pick(raw, "username", "user"),
		Password: pick(raw, "password"),
		Host:     host,
		Port:     port,
	}
	if c.Username == "" || c.Password == "" {
		return nil, fmt.Errorf("secret %s: missing username or password", secretID)
	}
	return c, nil
}

func fetchAMQPCredsFromEnv(host string, port int) (*AMQPCreds, error) {
	user := os.Getenv("RABBITMQ_USER")
	password := os.Getenv("RABBITMQ_PASSWORD")
	if user == "" || password == "" {
		return nil, fmt.Errorf("CREDS_SOURCE=env: RABBITMQ_USER and RABBITMQ_PASSWORD must be set")
	}
	if h := os.Getenv("RABBITMQ_HOST"); h != "" {
		host = h
	}
	if v := os.Getenv("RABBITMQ_PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil {
			return nil, fmt.Errorf("CREDS_SOURCE=env: RABBITMQ_PORT=%q: not an integer", v)
		}
		port = p
	}
	return &AMQPCreds{Username: user, Password: password, Host: host, Port: port}, nil
}

// URL builds an AMQP DSN with proper percent-encoding for the password.
func (a *AMQPCreds) URL() string {
	u := &url.URL{
		Scheme: "amqp",
		User:   url.UserPassword(a.Username, a.Password),
		Host:   fmt.Sprintf("%s:%d", a.Host, a.Port),
		Path:   "/",
	}
	return u.String()
}

// Redacted is a log-safe rendering that hides the password.
func (a *AMQPCreds) Redacted() string {
	return fmt.Sprintf("amqp://%s:***@%s:%d/", url.PathEscape(a.Username), a.Host, a.Port)
}
