// Package secrets fetches AMQP creds from AWS Secrets Manager at startup,
// mirroring services/oeecloud-worker/internal/secrets (AMQP subset only — the
// fan-out never touches Postgres). CO-5: no plaintext RABBITMQ_PASSWORD in
// compose env.
//
// The fan-out reuses the SAME least-privilege `oeecloud-worker` AMQP user
// (secret packiot/staging/rabbitmq-oeecloud-creds): that principal may declare
// its own topology, consume its own queues, and publish to the `oee` exchange —
// exactly the perms the fan-out needs (declare its queue, consume it, publish
// the re-tenanted clone back to `oee`).
//
// A CREDS_SOURCE=env escape hatch reads RABBITMQ_USER/RABBITMQ_PASSWORD from the
// environment for local compose.development where no IAM role is reachable.
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

// fetchSecretJSON is the Secrets Manager fetch, held in a package var purely as
// a test seam: secrets_test.go swaps it for a stub so "CREDS_SOURCE unset → SM
// path taken" can be asserted without AWS. Production never reassigns it.
var fetchSecretJSON = getSecretJSON

type AMQPCreds struct {
	Username string
	Password string
	Host     string
	Port     int
}

// FetchAMQPCreds reads {username, password} from the secret + uses the
// caller-supplied host/port (docker-network constants). CREDS_SOURCE=env skips
// Secrets Manager and reads RABBITMQ_USER/RABBITMQ_PASSWORD from env.
func FetchAMQPCreds(ctx context.Context, region, secretID, host string, port int) (*AMQPCreds, error) {
	if os.Getenv("CREDS_SOURCE") == credsSourceEnv {
		return fetchAMQPCredsFromEnv(host, port)
	}
	raw, err := fetchSecretJSON(ctx, region, secretID)
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

func (a *AMQPCreds) Redacted() string {
	return fmt.Sprintf("amqp://%s:***@%s:%d/", url.PathEscape(a.Username), a.Host, a.Port)
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

func pick(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

// fetchAMQPCredsFromEnv is the CREDS_SOURCE=env path (local dev only, ADR-0060
// P1). It replaces the RabbitMQ secret ($RABBITMQ_SECRET_ID → {username|user,
// password}) with:
//
//	RABBITMQ_USER      required (secret field username/user)
//	RABBITMQ_PASSWORD  required (secret field password)
//	RABBITMQ_HOST      optional, overrides the caller-supplied host
//	RABBITMQ_PORT      optional, overrides the caller-supplied port (integer)
//
// Missing user/password fails closed — never falls back to Secrets Manager or
// to empty creds. SECURITY: plaintext env is visible in `docker inspect` and to
// any same-UID process via /proc/<pid>/environ; keep CREDS_SOURCE unset in
// staging/prod.
func fetchAMQPCredsFromEnv(host string, port int) (*AMQPCreds, error) {
	user := os.Getenv("RABBITMQ_USER")
	password := os.Getenv("RABBITMQ_PASSWORD")
	if user == "" || password == "" {
		return nil, fmt.Errorf("CREDS_SOURCE=env: RABBITMQ_USER and RABBITMQ_PASSWORD must be set")
	}
	if h := os.Getenv("RABBITMQ_HOST"); h != "" {
		host = h
	}
	if p := os.Getenv("RABBITMQ_PORT"); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, fmt.Errorf("CREDS_SOURCE=env: RABBITMQ_PORT=%q: %w", p, err)
		}
		port = n
	}
	return &AMQPCreds{Username: user, Password: password, Host: host, Port: port}, nil
}
