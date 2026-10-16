package mirror

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"

	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/replicate"
)

// Role names the deployment is expected to hand the reflector (a mismatch is logged, never fatal: the grants are
// what limit a login, db/migrations/t-prod-reflector-roles).
const (
	SrcRole = "prod_reflector_ro" // production, SELECT only
	DstRole = "prod_reflector"    // staging, DML on the reflected tables
)

// Creds is one resolved login.
type Creds struct {
	Host, User, Password, Database string
	Port                           int
}

// LoadCreds resolves one side's login. Staging: Secrets Manager (secretEnv names the secret id: SRC_SECRET_ID =
// packiot/production/prod-reflector-ro-db-creds, written by provision-db-role.py on the PRODUCTION host and
// readable by staging's app role for that one ARN; PG_SECRET_ID = packiot/staging/prod-reflector-db-creds).
// Dev/tests: CREDS_SOURCE=env reads <prefix>_DB_HOST/_PORT/_USER/_PASSWORD/_NAME. No admin fallback.
func LoadCreds(ctx context.Context, secretEnv, prefix string, fetch replicate.SecretFetcher) (*Creds, error) {
	if os.Getenv("CREDS_SOURCE") == "env" {
		port, _ := strconv.Atoi(os.Getenv(prefix + "_DB_PORT"))
		if port == 0 {
			port = 5432
		}
		c := &Creds{Host: os.Getenv(prefix + "_DB_HOST"), Port: port, User: os.Getenv(prefix + "_DB_USER"),
			Password: os.Getenv(prefix + "_DB_PASSWORD"), Database: os.Getenv(prefix + "_DB_NAME")}
		if c.Host == "" || c.User == "" || c.Password == "" || c.Database == "" {
			return nil, fmt.Errorf("CREDS_SOURCE=env: %s_DB_HOST/_USER/_PASSWORD/_NAME are required", prefix)
		}
		return c, nil
	}
	id := os.Getenv(secretEnv)
	if id == "" {
		return nil, errors.New(secretEnv + " is empty")
	}
	region := os.Getenv("AWS_REGION")
	if region == "" {
		region = "us-east-1"
	}
	raw, err := fetch(ctx, region, id)
	if err != nil {
		return nil, err
	}
	str := func(keys ...string) string {
		for _, k := range keys {
			switch v := raw[k].(type) {
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
	port, _ := strconv.Atoi(str("port", "DB_PORT"))
	c := &Creds{Host: str("host", "DB_HOST"), Port: port, User: str("user", "DB_USER"),
		Password: str("password", "DB_PASSWORD"), Database: str("name", "DB_NAME")}
	if c.Host == "" || c.Port == 0 || c.User == "" || c.Password == "" || c.Database == "" {
		return nil, fmt.Errorf("secret %s: host, port, user, password and name are all required", id)
	}
	return c, nil
}
