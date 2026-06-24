// Package secrets fetches DB creds from AWS Secrets Manager at startup.
// CO-5 improvement: no plaintext DB passwords in compose env vars or
// .env. The EC2 IAM role grants packiot/staging/* + databaseCredentials-??????.
package secrets

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

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
//   packiot/staging/db   → {host, port, user, password, name}
//   databaseCredentials  → {DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME}
//
// pick() walks each candidate key in order and returns the first
// non-empty value. Adding more secrets later = add more aliases to
// the candidate lists.
func FetchDBCreds(ctx context.Context, region, secretID string) (*DBCreds, error) {
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
