// dbcreds.go — where the DB login comes from, and the pool built from it.
//
// barcode-service logs in as its own least-privilege role `barcode_service`
// (db/migrations/t-barcode-service-role), never the Postgres admin. Two sources:
//
//   - staging / production: AWS Secrets Manager, PG_SECRET_ID
//     (packiot/<env>/barcode-service-db-creds = {host, port, user, password, name}).
//     The password never sits in compose env, so `docker inspect` cannot show it
//     (CO-5). The host provisions the secret: services/barcode-service/README.md
//     § Provisioning the DB role.
//   - dev: CREDS_SOURCE=env reads DB_HOST / DB_PORT / DB_USER / DB_PASSWORD / DB_NAME
//     (a laptop has no IAM role to reach Secrets Manager).
//
// Fail closed: without CREDS_SOURCE=env an empty PG_SECRET_ID is a boot error,
// never a silent fall back to an admin secret or the old DB_USER=postgres default.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// dbRole is the login the deployment is expected to hand the service. Only used
// for the CREDS_SOURCE=env default and a boot-time warning; the role's grants
// are what actually limit it.
const dbRole = "barcode_service"

const credsSourceEnv = "env"

type dbCreds struct {
	Host     string
	Port     int
	User     string
	Password string
	Database string
}

// URL is a percent-encoded DSN, so a password with URL-syntactic characters
// cannot corrupt the parse.
func (c *dbCreds) URL(appName string) string {
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

// Redacted is the DSN with the password masked, for logs.
func (c *dbCreds) Redacted(appName string) string {
	return fmt.Sprintf("postgres://%s:***@%s:%d/%s?application_name=%s",
		url.PathEscape(c.User), c.Host, c.Port, c.Database, appName)
}

// secretFetcher returns the JSON fields of one Secrets Manager secret. A seam so
// tests cover the parsing without AWS.
type secretFetcher func(ctx context.Context, region, secretID string) (map[string]any, error)

// loadDBCreds picks the source from CREDS_SOURCE / PG_SECRET_ID (see the file comment).
func loadDBCreds(ctx context.Context, fetch secretFetcher) (*dbCreds, error) {
	if os.Getenv("CREDS_SOURCE") == credsSourceEnv {
		return dbCredsFromEnv()
	}
	secretID := os.Getenv("PG_SECRET_ID")
	if secretID == "" {
		return nil, errors.New("PG_SECRET_ID is empty (set it to packiot/<env>/barcode-service-db-creds, " +
			"or CREDS_SOURCE=env with DB_* in dev)")
	}
	raw, err := fetch(ctx, getenv("AWS_REGION", "us-east-1"), secretID)
	if err != nil {
		return nil, err
	}
	return dbCredsFromSecret(secretID, raw)
}

func dbCredsFromSecret(secretID string, raw map[string]any) (*dbCreds, error) {
	port, err := strconv.Atoi(pick(raw, "port", "DB_PORT"))
	if err != nil {
		return nil, fmt.Errorf("secret %s: port: %w", secretID, err)
	}
	c := &dbCreds{
		Host:     pick(raw, "host", "DB_HOST"),
		Port:     port,
		User:     pick(raw, "user", "DB_USER"),
		Password: pick(raw, "password", "DB_PASSWORD"),
		Database: pick(raw, "name", "DB_NAME"),
	}
	if c.Host == "" || c.Port == 0 || c.User == "" || c.Password == "" || c.Database == "" {
		return nil, fmt.Errorf("secret %s: host, port, user, password and name are all required", secretID)
	}
	return c, nil
}

// dbCredsFromEnv is the dev path. No password default: a loud boot failure beats
// an unhealthy pool nobody notices.
func dbCredsFromEnv() (*dbCreds, error) {
	port, err := strconv.Atoi(getenv("DB_PORT", "5432"))
	if err != nil {
		return nil, fmt.Errorf("CREDS_SOURCE=env: DB_PORT: %w", err)
	}
	c := &dbCreds{
		Host:     getenv("DB_HOST", "postgres"),
		Port:     port,
		User:     getenv("DB_USER", dbRole),
		Password: os.Getenv("DB_PASSWORD"),
		Database: getenv("DB_NAME", "packiot_analytics"),
	}
	if c.Password == "" {
		return nil, errors.New("CREDS_SOURCE=env: DB_PASSWORD must be set")
	}
	return c, nil
}

func pick(m map[string]any, keys ...string) string {
	for _, k := range keys {
		switch v := m[k].(type) {
		case string:
			if v != "" {
				return v
			}
		case float64:
			return strconv.FormatInt(int64(v), 10)
		}
	}
	return ""
}

// awsSecret is the production secretFetcher.
func awsSecret(ctx context.Context, region, secretID string) (map[string]any, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}
	out, err := secretsmanager.NewFromConfig(cfg).GetSecretValue(ctx,
		&secretsmanager.GetSecretValueInput{SecretId: &secretID})
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

// newPool is the service's one pool. The golden test builds it the same way.
func newPool(ctx context.Context, c *dbCreds) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(c.URL("barcode-service"))
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	pc.MaxConns = 5
	// pgbouncer transaction pooling breaks pgx's implicit prepared statements —
	// simple protocol is the stack-wide fix (see refdata-api/main.go). It is
	// ALSO what makes pg_advisory_xact_lock and the transaction-local
	// app.tenant_id stamp safe: transaction pooling pins one server backend for
	// the life of a tx, so both live for exactly our BEGIN…COMMIT.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	return pgxpool.NewWithConfig(ctx, pc)
}
