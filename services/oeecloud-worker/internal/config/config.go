// Package config loads runtime configuration from environment variables.
// Secrets (DB password, RabbitMQ password) are NOT in env — they are
// fetched from AWS Secrets Manager by main.go at startup. CO-5 phase 2.
//
// AMQP user `oeecloud-worker` is least-privilege on staging RabbitMQ:
// it can declare its own topology, consume from oeecloud-worker-q, and
// publish to oee-failed when retries are exhausted. It cannot touch
// other queues, the management UI, or read from the queue Node-RED owns.
package config

import (
	"os"
	"strconv"
)

type Config struct {
	// AWS Secrets Manager
	AWSRegion        string
	PGSecretID       string // packiot/staging/db
	RabbitMQSecretID string // packiot/staging/rabbitmq-oeecloud-creds

	// AMQP — host/port only. Username + password come from Secrets Manager.
	AMQPHost string
	AMQPPort int

	// Exchanges + queues. The worker SHARES the live `oee` topic exchange
	// (where edge-nodered publishes) but binds a SEPARATE queue so it can
	// run alongside the existing oeecloud-node-red without competing for
	// messages — both queues see every publish (fanout-style with `#` routing
	// key). Once parity is reached and Node-RED is decommissioned, this queue
	// becomes the only consumer.
	SourceExchange string // 'oee' (existing)
	WorkerQueue    string // 'oeecloud-worker-q' (new, this worker only)
	RetryExchange  string // 'oee-retry' (NEW — DLX target for nacks)
	RetryQueue     string // 'oeecloud-worker-q-retry-30s' (NEW — TTL 30s, DLX back to oee)
	FailedExchange string // 'oee-failed' (NEW — terminal, human inspection)
	FailedQueue    string // 'oeecloud-worker-q-failed' (NEW — no TTL, no DLX)
	RetryTTLMs     int    // 30000
	MaxRetries     int    // 5

	// Consumer tuning
	Prefetch int // 50 — bounded outstanding ack count

	// HTTP
	HealthPort int

	// Logging
	LogLevel string // 'debug' | 'info' | 'warn' | 'error'

	// ADR-0012 shadow DB (schema refactor live POC). Empty string
	// = disabled (default). When set, a second pgx pool is created
	// against the same host/user/password but overriding the
	// database name, and envelopes with source_type="refactored"
	// are routed there instead of the main pool. Preserves the
	// existing shadow_go_port routing (source_type="go" → schema
	// swap on main pool) untouched.
	PGShadowDBName string
}

func Load() (*Config, error) {
	return &Config{
		AWSRegion:        getenv("AWS_REGION", "us-east-1"),
		PGSecretID:       getenv("PG_SECRET_ID", "packiot/staging/db"),
		RabbitMQSecretID: getenv("RABBITMQ_SECRET_ID", "packiot/staging/rabbitmq-oeecloud-creds"),
		AMQPHost:         getenv("RABBITMQ_HOST", "rabbitmq"),
		AMQPPort:         getenvInt("RABBITMQ_PORT", 5672),
		SourceExchange:   getenv("SOURCE_EXCHANGE", "oee"),
		WorkerQueue:      getenv("WORKER_QUEUE", "oeecloud-worker-q"),
		RetryExchange:    getenv("RETRY_EXCHANGE", "oee-retry"),
		RetryQueue:       getenv("RETRY_QUEUE", "oeecloud-worker-q-retry-30s"),
		FailedExchange:   getenv("FAILED_EXCHANGE", "oee-failed"),
		FailedQueue:      getenv("FAILED_QUEUE", "oeecloud-worker-q-failed"),
		RetryTTLMs:       getenvInt("RETRY_TTL_MS", 30000),
		MaxRetries:       getenvInt("MAX_RETRIES", 5),
		Prefetch:         getenvInt("PREFETCH", 50),
		HealthPort:       getenvInt("HEALTH_PORT", 9101),
		LogLevel:         getenv("LOG_LEVEL", "info"),
		PGShadowDBName:   getenv("POSTGRES_SHADOW_DB_NAME", ""),
	}, nil
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
