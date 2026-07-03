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
	"os"
	"strconv"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

// credsSourceEnv is the literal value of $CREDS_SOURCE that switches
// FetchDBCreds + FetchAMQPCreds from AWS Secrets Manager to plain env
// vars. Used ONLY in compose.development.yml — never in staging/prod.
//
// Why this gate exists (issue #52): both workers are first-party Go
// services that need DB + AMQP creds at boot. On staging the EC2 IAM
// role grants packiot/staging/* and the SM call works. On a local dev
// laptop there's no IAM role + no SM reachability, so the call blocks
// for ~30s then fails — making `make up` unusable for the OEE pipeline.
// CREDS_SOURCE=env tells the worker "trust the compose env vars" so
// you can wire it against the in-stack postgres + rabbitmq.
//
// SECURITY: this is NOT the prod path because plaintext passwords land
// in `docker inspect` output and any process on the host can read them
// via /proc/<pid>/environ. Keep CREDS_SOURCE unset (or absent) in
// staging/prod so the SM path stays canonical. CO-5 phase 2 is
// specifically about removing plaintext creds from the production
// surface — this fallback is dev-only ergonomics.
const credsSourceEnv = "env"

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
//
// When $CREDS_SOURCE=env, skip the SM call entirely and read from env
// vars: DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME. Used only in
// compose.development.yml — see credsSourceEnv doc above.
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

// FetchAMQPCreds reads {username, password} from the secret + uses
// caller-supplied host/port (docker-network constants).
//
// When $CREDS_SOURCE=env, skip the SM call entirely and read from env
// vars: RABBITMQ_USER, RABBITMQ_PASSWORD, RABBITMQ_HOST (optional —
// falls back to the host arg), RABBITMQ_PORT (optional — falls back
// to the port arg). Used only in compose.development.yml.
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
	return c.URLForDatabase(appName, c.Database)
}

// URLForDatabase is URL() with the database name overridden. Used to
// connect the same creds against a sibling DB (e.g. packiot_shadow for
// the ADR-0012 refactor POC — same host, same user, same password,
// different Path).
func (c *DBCreds) URLForDatabase(appName, dbName string) string {
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(c.User, c.Password),
		Host:   fmt.Sprintf("%s:%d", c.Host, c.Port),
		Path:   "/" + dbName,
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

// fetchDBCredsFromEnv is the CREDS_SOURCE=env path. Reads DB_* env
// vars with sensible defaults for host/port/database (matching
// compose.development.yml's postgres service). User + password have
// no defaults — if either is empty we error out instead of silently
// connecting with insecure creds. Better a loud crash at boot than
// a worker that mysteriously can't auth.
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
	return &DBCreds{
		Host:     host,
		Port:     port,
		User:     user,
		Password: password,
		Database: database,
	}, nil
}

// fetchAMQPCredsFromEnv is the CREDS_SOURCE=env path for AMQP. The
// caller-supplied host/port act as defaults — RABBITMQ_HOST /
// RABBITMQ_PORT in the env will override them, which matches how
// dev compose tends to set the broker address.
func fetchAMQPCredsFromEnv(host string, port int) (*AMQPCreds, error) {
	user := os.Getenv("RABBITMQ_USER")
	password := os.Getenv("RABBITMQ_PASSWORD")
	if user == "" || password == "" {
		return nil, fmt.Errorf("CREDS_SOURCE=env: RABBITMQ_USER and RABBITMQ_PASSWORD must be set")
	}
	if h := os.Getenv("RABBITMQ_HOST"); h != "" {
		host = h
	}
	p, err := envInt("RABBITMQ_PORT", port)
	if err != nil {
		return nil, fmt.Errorf("CREDS_SOURCE=env: %w", err)
	}
	port = p
	return &AMQPCreds{
		Username: user,
		Password: password,
		Host:     host,
		Port:     port,
	}, nil
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
