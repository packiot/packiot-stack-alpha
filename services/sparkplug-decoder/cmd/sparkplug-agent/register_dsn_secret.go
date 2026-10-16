package main

import (
	"context"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/secrets"
)

// AGENT_DB_SECRET_ID: Secrets Manager id of the agent's least-privilege DB login
// (t-sparkplug-agent-role; packiot/<env>/sparkplug-agent-db-creds, written by
// scripts/ops/provision-db-role.py --service sparkplug-agent). Production uses
// it so the password never sits in the host .env or the container environment.
// Fetched once per process (link health, derive rules and capture all build a
// DSN at boot) and cached, error included: a restart re-reads a rotated secret.
var (
	secretDSNOnce sync.Once
	secretDSN     string
	secretDSNErr  error
	// fetchDBDSN is a test seam; production never reassigns it.
	fetchDBDSN = secrets.FetchDBDSN
)

func secretRegisterDSN() (dsn string, ok bool, err error) {
	id := strings.TrimSpace(os.Getenv("AGENT_DB_SECRET_ID"))
	if id == "" {
		return "", false, nil
	}
	secretDSNOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		secretDSN, secretDSNErr = fetchDBDSN(ctx, getenv("AWS_REGION", "us-east-1"), id, "sparkplug-agent-register")
	})
	return secretDSN, true, secretDSNErr
}
