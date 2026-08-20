// Package config loads shadow-mirror runtime config from env.
//
// Two DB pool connections:
//   - Main pool: staging packiot DB (reads user_logs, writes to shadow_go_port schema)
//   - Shadow pool: packiot_shadow DB (writes to public schema of refactored POC)
//
// Both use the same DB credentials from AWS Secrets Manager (packiot/staging/db);
// only the target database name differs.
//
// SHADOW_MIRROR_ENABLED gates the whole thing. Default = false so a
// deploy with the container present but flag unset is a no-op — same
// dead-safe posture as PR #171's POSTGRES_SHADOW_DB_NAME.
package config

import (
	"os"
	"strconv"
)

type Config struct {
	// AWS
	AWSRegion  string
	PGSecretID string

	// DBs — main = packiot (reads user_logs, writes shadow_go_port),
	// shadow = packiot_shadow (writes public). Empty PGShadowDBName =
	// disable shadow-DB writes (writes ONLY shadow_go_port).
	PGDBName       string // typically "packiot"
	PGShadowDBName string // typically "packiot_shadow"; empty disables shadow-DB writes

	// Loop tuning
	PollIntervalMs int  // between successive user_logs polls
	BatchSize      int  // rows per iteration; keeps single-batch latency bounded
	MaxRetries     int  // per-row retry cap before DLQ
	Enabled        bool // master toggle

	// HTTP
	HealthPort int

	// Logging
	LogLevel string
}

func Load() *Config {
	return &Config{
		AWSRegion:      getenv("AWS_REGION", "us-east-1"),
		PGSecretID:     getenv("PG_SECRET_ID", "packiot/staging/db"),
		PGDBName:       getenv("PG_DB_NAME", "packiot"),
		PGShadowDBName: getenv("PG_SHADOW_DB_NAME", "packiot_shadow"),
		PollIntervalMs: getenvInt("POLL_INTERVAL_MS", 2000),
		BatchSize:      getenvInt("BATCH_SIZE", 100),
		MaxRetries:     getenvInt("MAX_RETRIES", 5),
		Enabled:        getenv("SHADOW_MIRROR_ENABLED", "false") == "true",
		HealthPort:     getenvInt("HEALTH_PORT", 9103), // distinct from oeecloud-worker (9101) + edge-transformer (9102)
		LogLevel:       getenv("LOG_LEVEL", "info"),
	}
}

func getenv(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func getenvInt(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
