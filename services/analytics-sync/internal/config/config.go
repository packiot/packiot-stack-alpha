// Package config loads shadow-mirror runtime config from env.
//
// Two DB pool connections:
//   - Main pool: staging packiot DB (reads user_logs, writes to shadow_go_port schema)
//   - Shadow pool: packiot_analytics DB (writes to public schema of refactored POC)
//
// Both use the same DB login, DB_USER/DB_PASSWORD from env (cmd/shadow-mirror dbCredsFromEnv; no
// default user); only the target database name differs. Idle mode needs no credentials at all.
//
// SHADOW_MIRROR_ENABLED gates the whole thing. Default = false so a
// deploy with the container present but flag unset is a no-op — same
// dead-safe posture as PR #171's POSTGRES_ANALYTICS_DB_NAME.
package config

import (
	"os"
	"strconv"
)

type Config struct {
	// DBs — main = packiot (reads user_logs, writes shadow_go_port),
	// shadow = packiot_analytics (writes public). Empty PGAnalyticsDBName =
	// disable shadow-DB writes (writes ONLY shadow_go_port).
	PGDBName          string // typically "packiot"
	PGAnalyticsDBName string // typically "packiot_analytics"; empty disables shadow-DB writes

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
		PGDBName:          getenv("PG_DB_NAME", "packiot"),
		PGAnalyticsDBName: getenv("PG_ANALYTICS_DB_NAME", "packiot_analytics"),
		PollIntervalMs:    getenvInt("POLL_INTERVAL_MS", 2000),
		BatchSize:         getenvInt("BATCH_SIZE", 100),
		MaxRetries:        getenvInt("MAX_RETRIES", 5),
		Enabled:           getenv("SHADOW_MIRROR_ENABLED", "false") == "true",
		HealthPort:        getenvInt("HEALTH_PORT", 9103), // distinct from oeecloud-worker (9101) + edge-transformer (9102)
		LogLevel:          getenv("LOG_LEVEL", "info"),
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
