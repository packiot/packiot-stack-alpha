// Package config holds runtime config. Most secrets come from AWS Secrets
// Manager at startup (see secrets/), NOT from env vars — that's the CO-5
// improvement vs the TS mirror-worker which read POSTGRES_* / RABBITMQ_*
// via .env interpolation.
package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	AWSRegion string

	// Secret IDs (not the values — values fetched at boot via secrets pkg).
	ProdDBSecretID    string // 'databaseCredentials' — prod awslambda creds (SELECT-only)
	StagingDBSecretID string // 'packiot/staging/db' — staging postgres creds

	// Source identity embedded in DLQ / cursor / mirror_id_map rows.
	// Using 'cpack-prod-go' during parallel-run with the TS mirror-worker
	// (source='cpack-prod') so the two have independent cursors + mappings.
	// Cut over by changing this back to 'cpack-prod' after the TS is stopped.
	SourceName          string
	ProdEnterpriseID    int
	StagingEnterpriseID int

	// Polling cadence + per-row pacing.
	PollIntervalSec int
	BatchSize       int
	PerPostDelayMs  int

	// Staging edge-api — reached on the packiot-net docker network.
	StagingAPIBaseURL string

	// Event-event interval-overlap matcher thresholds (Phase A4b).
	// EventMinOverlapSec — minimum overlap to count as a match.
	// EventMaxStartDriftSec — staging.ts_event must be no earlier than
	// prod.ts_event - this. Prevents long-stale open staging events
	// (ts_end IS NULL, opened days ago) from matching every later prod
	// event by virtue of the "open window matches everything" overlap.
	EventMinOverlapSec    int
	EventMaxStartDriftSec int

	// HTTP /health server.
	HealthPort int

	// Active-PO reconciliation loop. Closes the ~95% gap left by
	// user_logs-based PO replay: most prod CPACK POs are created by PLC
	// SparkPlug parameter writes (30800–30899) that bypass edge-api's
	// audit middleware, so order-created / order-started rows are rare in
	// user_logs. The reconciler periodically diffs prod active POs vs
	// staging active POs (by id_order) and backfills the missing ones via
	// the same /create + /start endpoints we use in the user_logs handlers.
	ReconcileEnabled     bool
	ReconcileIntervalSec int
	ReconcileMaxPerRun   int

	// Logging.
	LogLevel string
}

func Load() (*Config, error) {
	cfg := &Config{
		AWSRegion:           getenv("AWS_REGION", "us-east-1"),
		ProdDBSecretID:      getenv("PROD_DB_SECRET_ID", "databaseCredentials"),
		StagingDBSecretID:   getenv("STAGING_DB_SECRET_ID", "packiot/staging/db"),
		SourceName:          getenv("SOURCE_NAME", "cpack-prod-go"),
		ProdEnterpriseID:    getenvInt("PROD_ENTERPRISE_ID", 1),
		StagingEnterpriseID: getenvInt("STAGING_ENTERPRISE_ID", 3),
		PollIntervalSec:     getenvInt("POLL_INTERVAL_SEC", 60),
		BatchSize:           getenvInt("BATCH_SIZE", 50),
		PerPostDelayMs:      getenvInt("PER_POST_DELAY_MS", 50),
		StagingAPIBaseURL:   getenv("STAGING_API_URL", "http://edge-api:8080"),
		EventMinOverlapSec:    getenvInt("EVENT_MIN_OVERLAP_SEC", 30),
		EventMaxStartDriftSec: getenvInt("EVENT_MAX_START_DRIFT_SEC", 600),
		HealthPort:          getenvInt("HEALTH_PORT", 9102),
		ReconcileEnabled:     getenvBool("RECONCILE_ENABLED", true),
		ReconcileIntervalSec: getenvInt("RECONCILE_INTERVAL_SEC", 300),
		ReconcileMaxPerRun:   getenvInt("RECONCILE_MAX_PER_RUN", 20),
		LogLevel:            getenv("LOG_LEVEL", "info"),
	}
	// Sanity checks
	if cfg.ProdEnterpriseID <= 0 {
		return nil, fmt.Errorf("PROD_ENTERPRISE_ID required")
	}
	if cfg.StagingEnterpriseID <= 0 {
		return nil, fmt.Errorf("STAGING_ENTERPRISE_ID required")
	}
	return cfg, nil
}

func getenv(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func getenvInt(name string, fallback int) int {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}

func getenvBool(name string, fallback bool) bool {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	switch v {
	case "1", "true", "TRUE", "True", "yes":
		return true
	case "0", "false", "FALSE", "False", "no":
		return false
	}
	return fallback
}
