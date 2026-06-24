// Package secrets fetches DB + AMQP creds from AWS Secrets Manager at
// startup. CO-5: no plaintext POSTGRES_PASSWORD / RABBITMQ_PASSWORD in
// compose env (visible via `docker inspect`).
//
// AMQP user `oeecloud-worker` was provisioned on staging RabbitMQ with
// least-privilege perms (configure: own topology, write: own queues +
// oee-failed exchange, read: source exchanges + own consume queue).
// Creds live in packiot/staging/rabbitmq-oeecloud-creds.
//
// Two secret shapes supported by FetchDBCreds (so this same code works
// against staging's packiot/staging/db AND prod's databaseCredentials):
//
//	packiot/staging/db   → {host, port, user, password, name}
//	databaseCredentials  → {DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME}
//
// pick(keys...) walks the candidates in order and returns the first
// non-empty match. Mirrors the helper in services/mirror-worker-go.
package secrets

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

type DBCreds struct {
	Host     string
	Port     int
	User     string
	Password string
	Database string
}

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

func pickInt(m map[string]any, keys ...string) (int, error) {
	s := pick(m, keys...)
	if s == "" {
		return 0, nil
	}
	var n int
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		return 0, fmt.Errorf("not an integer: %q", s)
	}
	return n, nil
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

// FetchDBCreds tolerates both lowercase ({host,...}) and uppercase-
// prefixed ({DB_HOST,...}) field naming conventions.
func FetchDBCreds(ctx context.Context, region, secretID string) (*DBCreds, error) {
	raw, err := getSecretJSON(ctx, region, secretID)
	if err != nil {
		return nil, err
	}
	port, perr := pickInt(raw, "port", "DB_PORT")
	if perr != nil {
		return nil, fmt.Errorf("secret %s: %w", secretID, perr)
	}
	c := &DBCreds{
		Host:     pick(raw, "host", "DB_HOST"),
		Port:     port,
		User:     pick(raw, "user", "DB_USER"),
		Password: pick(raw, "password", "DB_PASSWORD"),
		Database: pick(raw, "name", "db", "DB_NAME", "database"),
	}
	missing := []string{}
	if c.Host == "" {
		missing = append(missing, "host/DB_HOST")
	}
	if c.Port == 0 {
		missing = append(missing, "port/DB_PORT")
	}
	if c.User == "" {
		missing = append(missing, "user/DB_USER")
	}
	if c.Password == "" {
		missing = append(missing, "password/DB_PASSWORD")
	}
	if c.Database == "" {
		missing = append(missing, "name/db/DB_NAME/database")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("secret %s: missing fields %v", secretID, missing)
	}
	return c, nil
}

// FetchAMQPCreds reads {username, password} from the secret + uses
// caller-supplied host/port (docker-network constants).
func FetchAMQPCreds(ctx context.Context, region, secretID, host string, port int) (*AMQPCreds, error) {
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

// URL builds a postgres DSN with proper percent-encoding so passwords
// containing URL-syntactic chars (':', '@', '<', '?', '#', '/' …) don't
// corrupt the parse. Hand-rolling fmt.Sprintf breaks here — pgx parses
// the DSN as a URL and would split on the wrong ':'.
func (c *DBCreds) URL(appName string) string {
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(c.User, c.Password),
		Host:   fmt.Sprintf("%s:%d", c.Host, c.Port),
		Path:   "/" + c.Database,
	}
	q := u.Query()
	q.Set("sslmode", "disable")
	q.Set("application_name", appName)
	u.RawQuery = q.Encode()
	return u.String()
}

func (c *DBCreds) Redacted(appName string) string {
	return fmt.Sprintf("postgres://%s:***@%s:%d/%s?application_name=%s",
		url.PathEscape(c.User), c.Host, c.Port, c.Database, appName)
}

