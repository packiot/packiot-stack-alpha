// Package secrets fetches DB creds from AWS Secrets Manager at startup.
// CO-5 improvement: no plaintext DB passwords in compose env vars or
// .env. The EC2 IAM role grants packiot/staging/* + databaseCredentials-??????.
package secrets

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

// DBCreds is the shape both packiot/staging/db and databaseCredentials use.
// Slight diff: packiot/staging/db has 'name' (database), databaseCredentials
// has 'db'. We accept both via json tag aliases on a custom Unmarshal.
type DBCreds struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
	Database string `json:"-"`
}

// rawDBCreds catches both 'name' and 'db' database-name fields. Either
// can be present; non-empty wins. Port can be string or int in different
// secret schemas; intOrString normalises.
type rawDBCreds struct {
	Host     string `json:"host"`
	Port     intOrString `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
	Name     string `json:"name"`
	DB       string `json:"db"`
}

// intOrString accepts either a JSON number or a JSON string-encoded
// number. Some secret managers normalise everything to strings.
type intOrString int

func (i *intOrString) UnmarshalJSON(b []byte) error {
	var n int
	if err := json.Unmarshal(b, &n); err == nil {
		*i = intOrString(n)
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		var nn int
		if _, err := fmt.Sscanf(s, "%d", &nn); err != nil {
			return fmt.Errorf("port string %q is not an integer: %w", s, err)
		}
		*i = intOrString(nn)
		return nil
	}
	return fmt.Errorf("port: not a number or string-number")
}

// FetchDBCreds pulls + parses a JSON secret into DBCreds.
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
	var raw rawDBCreds
	if err := json.Unmarshal([]byte(*out.SecretString), &raw); err != nil {
		return nil, fmt.Errorf("parse secret %s: %w", secretID, err)
	}
	dbName := raw.Name
	if dbName == "" {
		dbName = raw.DB
	}
	if dbName == "" {
		return nil, fmt.Errorf("secret %s: missing 'name' or 'db' field", secretID)
	}
	return &DBCreds{
		Host:     raw.Host,
		Port:     int(raw.Port),
		User:     raw.User,
		Password: raw.Password,
		Database: dbName,
	}, nil
}

// URL builds a postgres connection string from the creds. application_name
// is set so pg_stat_activity shows which client is connected.
func (c *DBCreds) URL(appName string) string {
	return fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable&application_name=%s",
		c.User, c.Password, c.Host, c.Port, c.Database, appName)
}

// Redacted returns a URL with the password masked, for logging.
func (c *DBCreds) Redacted(appName string) string {
	return fmt.Sprintf("postgres://%s:***@%s:%d/%s?application_name=%s",
		c.User, c.Host, c.Port, c.Database, appName)
}
