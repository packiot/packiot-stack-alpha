package replicate

// destcreds.go — where the DEST (new-stack packiot_analytics) login comes from.
//
// legacy-replicator writes the analytics DB as its own least-privilege role
// `legacy_replicator` (db/migrations/t-legacy-replicator-role), never the Postgres
// admin. Two sources, same contract as stream-engine / barcode-service:
//
//   - staging / production: AWS Secrets Manager, PG_SECRET_ID
//     (packiot/<env>/legacy-replicator-db-creds = {host, port, user, password, name}).
//     The password never sits in compose env, so `docker inspect` cannot show it.
//   - dev / tests: CREDS_SOURCE=env reads DEST_DB_HOST / DEST_DB_PORT / DEST_DB_USER /
//     DEST_DB_PASSWORD / DEST_DB_NAME (Config.Dest*).
//
// Fail closed: without CREDS_SOURCE=env an empty PG_SECRET_ID is a boot error, never a
// fall back to an admin secret or the old DEST_DB_USER=postgres default.
//
// The SOURCE (legacy packiot40) login is NOT handled here and is unchanged: it still
// comes from LEGACY_DB_* exactly as before.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

// DestRole is the login the deployment is expected to hand the replicator's DEST pool.
// Only the CREDS_SOURCE=env default and a boot warning use it; the grants are what
// actually limit the role.
const DestRole = "legacy_replicator"

const credsSourceEnv = "env"

// DestCreds is the resolved DEST login.
type DestCreds struct {
	Host     string
	Port     int
	User     string
	Password string
	Database string
}

// SecretFetcher returns the JSON fields of one Secrets Manager secret (a seam for tests).
type SecretFetcher func(ctx context.Context, region, secretID string) (map[string]any, error)

// LoadDestCreds picks the DEST login source from CREDS_SOURCE / PG_SECRET_ID.
func LoadDestCreds(ctx context.Context, cfg *Config, fetch SecretFetcher) (*DestCreds, error) {
	if os.Getenv("CREDS_SOURCE") == credsSourceEnv {
		c := &DestCreds{Host: cfg.DestHost, Port: cfg.DestPort, User: cfg.DestUser,
			Password: cfg.DestPassword, Database: cfg.DestDBName}
		if c.Password == "" {
			return nil, errors.New("CREDS_SOURCE=env: DEST_DB_PASSWORD must be set")
		}
		return c, nil
	}
	secretID := os.Getenv("PG_SECRET_ID")
	if secretID == "" {
		return nil, errors.New("PG_SECRET_ID is empty (set it to packiot/<env>/legacy-replicator-db-creds, " +
			"or CREDS_SOURCE=env with DEST_DB_* in dev)")
	}
	region := os.Getenv("AWS_REGION")
	if region == "" {
		region = "us-east-1"
	}
	raw, err := fetch(ctx, region, secretID)
	if err != nil {
		return nil, err
	}
	return destCredsFromSecret(secretID, raw)
}

func destCredsFromSecret(secretID string, raw map[string]any) (*DestCreds, error) {
	port, err := strconv.Atoi(pick(raw, "port", "DB_PORT"))
	if err != nil {
		return nil, fmt.Errorf("secret %s: port: %w", secretID, err)
	}
	c := &DestCreds{
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

// AWSSecret is the production SecretFetcher.
func AWSSecret(ctx context.Context, region, secretID string) (map[string]any, error) {
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
