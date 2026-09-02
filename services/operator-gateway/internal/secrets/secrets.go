// Package secrets fetches the read-only Postgres creds the operator-adapter's
// topic resolver needs, from AWS Secrets Manager at startup. CO-5: no plaintext
// POSTGRES_PASSWORD in compose env (visible via `docker inspect`).
//
// This is a trimmed sibling of services/oeecloud-worker/internal/secrets — only
// the DB path is kept (the adapter has no AMQP). Two secret shapes are
// tolerated so the same code works against staging's packiot/staging/db AND a
// prod-style databaseCredentials secret:
//
//	packiot/staging/db   → {host, port, user, password, name}
//	databaseCredentials  → {DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME}
//
// pick(keys...) walks the candidates in order and returns the first non-empty
// match.
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

// credsSourceEnv is the literal value of $CREDS_SOURCE that switches
// FetchDBCreds from AWS Secrets Manager to plain env vars. Used ONLY in
// compose.development.yml — never in staging/prod. On a local dev laptop
// there's no IAM role + no SM reachability, so the SM call would block ~30s
// then fail. CREDS_SOURCE=env tells the adapter "trust the compose env vars".
//
// SECURITY: not the prod path — plaintext passwords land in `docker inspect`
// output. Keep CREDS_SOURCE unset in staging/prod so the SM path stays
// canonical.
const credsSourceEnv = "env"

// DBCreds carries a resolved Postgres connection.
type DBCreds struct {
	Host     string
	Port     int
	User     string
	Password string
	Database string
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

// FetchDBCreds tolerates both lowercase ({host,...}) and uppercase-prefixed
// ({DB_HOST,...}) field naming conventions. When $CREDS_SOURCE=env, skips the
// SM call entirely and reads from DB_HOST / DB_PORT / DB_USER / DB_PASSWORD /
// DB_NAME env vars (dev only).
func FetchDBCreds(ctx context.Context, region, secretID string) (*DBCreds, error) {
	if os.Getenv("CREDS_SOURCE") == credsSourceEnv {
		return fetchDBCredsFromEnv()
	}
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

// URL builds a postgres DSN with proper percent-encoding so passwords
// containing URL-syntactic chars (':', '@', '?', '#', '/' …) don't corrupt the
// parse. The resolver only ever reads, but the connection itself is not marked
// read-only at the transport level — read-only intent is enforced by the
// resolver issuing SELECT-only statements against a least-privilege role.
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

// fetchDBCredsFromEnv is the CREDS_SOURCE=env path. Reads DB_* env vars with
// sensible defaults for host/port/database (matching compose.development.yml's
// postgres service). User + password have no defaults — a loud crash at boot
// beats an adapter that mysteriously can't auth.
func fetchDBCredsFromEnv() (*DBCreds, error) {
	host := envOr("DB_HOST", "postgres")
	port, err := envInt("DB_PORT", 5432)
	if err != nil {
		return nil, fmt.Errorf("CREDS_SOURCE=env: %w", err)
	}
	user := os.Getenv("DB_USER")
	password := os.Getenv("DB_PASSWORD")
	database := envOr("DB_NAME", "packiot")
	if user == "" || password == "" {
		return nil, fmt.Errorf("CREDS_SOURCE=env: DB_USER and DB_PASSWORD must be set (empty defaults are not allowed)")
	}
	return &DBCreds{Host: host, Port: port, User: user, Password: password, Database: database}, nil
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func envInt(name string, fallback int) (int, error) {
	v := os.Getenv(name)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s=%q: not an integer", name, v)
	}
	return n, nil
}
