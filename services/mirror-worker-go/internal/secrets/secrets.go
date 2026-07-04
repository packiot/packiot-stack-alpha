// Package secrets fetches DB creds from AWS Secrets Manager at startup.
// CO-5 improvement: no plaintext DB passwords in compose env vars or
// .env. The EC2 IAM role grants packiot/staging/* + databaseCredentials-??????.
package secrets

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

// credsSourceEnv is the literal value of $CREDS_SOURCE that switches
// FetchDBCreds from AWS Secrets Manager to plain env vars. Used ONLY
// in compose.development.yml — never in staging/prod.
//
// Why this gate exists (issue #52): mirror-worker-go fetches creds for
// TWO postgres clusters (prod via PROD_DB_SECRET_ID, staging via
// STAGING_DB_SECRET_ID). On staging EC2 the IAM role grants both. On a
// laptop neither is reachable, so the worker can't even reach
// main()'s polling loop without SM.
//
// In env mode, the dispatch routes to PROD_* or STAGING_* env vars
// based on whether the secretID looks like the prod or staging one
// (see envPrefixForSecretID). The user supplies whichever set they
// want — for local-dev, "prod = staging postgres" is a reasonable
// degenerate case (the worker will just see no new rows to replay).
//
// SECURITY: this is NOT the prod path because plaintext passwords land
// in `docker inspect` output and any process on the host can read them
// via /proc/<pid>/environ. Keep CREDS_SOURCE unset in staging/prod.
const credsSourceEnv = "env"

// DBCreds is the unified shape after normalisation. Different secrets
// in this project use different key names — we parse via a flexible
// map and pick whichever variant of each field is populated.
type DBCreds struct {
	Host     string
	Port     int
	User     string
	Password string
	Database string
}

// pick returns the first non-empty value from a list of keys looked up
// in the raw secret map. Lets one parser handle multiple key naming
// conventions ('host' vs 'DB_HOST', 'name' vs 'DB_NAME' vs 'db', etc).
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

// FetchDBCreds pulls + parses a JSON secret into DBCreds. Tolerates
// both naming conventions used in this project:
//
//	packiot/staging/db   → {host, port, user, password, name}
//	databaseCredentials  → {DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME}
//
// pick() walks each candidate key in order and returns the first
// non-empty value. Adding more secrets later = add more aliases to
// the candidate lists.
func FetchDBCreds(ctx context.Context, region, secretID string) (*DBCreds, error) {
	if os.Getenv("CREDS_SOURCE") == credsSourceEnv {
		return fetchDBCredsFromEnv(secretID)
	}
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}
	sm := secretsmanager.NewFromConfig(cfg)
	out, err := sm.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: &secretID,
	})
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

	host := pick(raw, "host", "DB_HOST")
	port, perr := pickInt(raw, "port", "DB_PORT")
	if perr != nil {
		return nil, fmt.Errorf("secret %s: %w", secretID, perr)
	}
	user := pick(raw, "user", "DB_USER")
	password := pick(raw, "password", "DB_PASSWORD")
	database := pick(raw, "name", "db", "DB_NAME", "database")

	missing := []string{}
	if host == "" {
		missing = append(missing, "host/DB_HOST")
	}
	if port == 0 {
		missing = append(missing, "port/DB_PORT")
	}
	if user == "" {
		missing = append(missing, "user/DB_USER")
	}
	if password == "" {
		missing = append(missing, "password/DB_PASSWORD")
	}
	if database == "" {
		missing = append(missing, "name/db/DB_NAME/database")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("secret %s: missing fields %v", secretID, missing)
	}
	return &DBCreds{
		Host:     host,
		Port:     port,
		User:     user,
		Password: password,
		Database: database,
	}, nil
}

// URL builds a postgres connection string from the creds. Uses net/url
// so passwords with URL-unsafe chars (':', '@', '<', '?', '#', '/' …)
// get percent-encoded properly. Hand-rolling fmt.Sprintf would break:
// the prod awslambda password contains '<' + ':' which pgx then tries
// to interpret as a port number ("invalid port" error).
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

// Redacted returns a URL with the password masked, for logging.
func (c *DBCreds) Redacted(appName string) string {
	return fmt.Sprintf("postgres://%s:***@%s:%d/%s?application_name=%s",
		url.PathEscape(c.User), c.Host, c.Port, c.Database, appName)
}

// envPrefixForSecretID picks the env-var prefix based on whether the
// requested secret looks like the prod or staging one. Heuristic:
//
//   - secretID containing "staging" (case-insensitive) → STAGING_DB_*
//   - everything else                                  → PROD_DB_*
//
// This matches the defaults in internal/config (ProdDBSecretID =
// "databaseCredentials", StagingDBSecretID = "packiot/staging/db") so
// callers don't need to change. If you override either secretID via env
// to something exotic, set CREDS_SOURCE back to the SM path or rename
// to include "staging" / not.
func envPrefixForSecretID(secretID string) string {
	if strings.Contains(strings.ToLower(secretID), "staging") {
		return "STAGING_DB_"
	}
	return "PROD_DB_"
}

// fetchDBCredsFromEnv is the CREDS_SOURCE=env path. Reads <prefix>HOST,
// <prefix>PORT, <prefix>USER, <prefix>PASSWORD, <prefix>NAME where the
// prefix is derived from the requested secretID.
//
// Defaults match compose.development.yml's postgres service. User +
// password have NO defaults — if either is empty we error out instead
// of silently connecting with insecure creds.
func fetchDBCredsFromEnv(secretID string) (*DBCreds, error) {
	prefix := envPrefixForSecretID(secretID)
	host := envOr(prefix+"HOST", "postgres")
	port, err := envInt(prefix+"PORT", 5432)
	if err != nil {
		return nil, fmt.Errorf("CREDS_SOURCE=env (%s): %w", secretID, err)
	}
	user := os.Getenv(prefix + "USER")
	password := os.Getenv(prefix + "PASSWORD")
	database := envOr(prefix+"NAME", "packiot")
	if user == "" || password == "" {
		return nil, fmt.Errorf("CREDS_SOURCE=env (%s): %sUSER and %sPASSWORD must be set", secretID, prefix, prefix)
	}
	return &DBCreds{
		Host:     host,
		Port:     port,
		User:     user,
		Password: password,
		Database: database,
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
