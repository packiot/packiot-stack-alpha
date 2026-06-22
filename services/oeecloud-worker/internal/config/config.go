// Package config loads runtime configuration from environment variables.
// Mirrors the env-driven pattern used by mirror-worker.
package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	// AMQP
	AMQPUser     string
	AMQPPassword string
	AMQPHost     string
	AMQPPort     int

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

	// Postgres (placeholder for next session — handlers will use it)
	PGHost     string
	PGPort     int
	PGUser     string
	PGPassword string
	PGDatabase string

	// HTTP
	HealthPort int

	// Logging
	LogLevel string // 'debug' | 'info' | 'warn' | 'error'
}

func Load() (*Config, error) {
	cfg := &Config{
		AMQPUser:       getenv("RABBITMQ_USER", "packiot"),
		AMQPPassword:   getenv("RABBITMQ_PASSWORD", ""),
		AMQPHost:       getenv("RABBITMQ_HOST", "rabbitmq"),
		AMQPPort:       getenvInt("RABBITMQ_PORT", 5672),
		SourceExchange: getenv("SOURCE_EXCHANGE", "oee"),
		WorkerQueue:    getenv("WORKER_QUEUE", "oeecloud-worker-q"),
		RetryExchange:  getenv("RETRY_EXCHANGE", "oee-retry"),
		RetryQueue:     getenv("RETRY_QUEUE", "oeecloud-worker-q-retry-30s"),
		FailedExchange: getenv("FAILED_EXCHANGE", "oee-failed"),
		FailedQueue:    getenv("FAILED_QUEUE", "oeecloud-worker-q-failed"),
		RetryTTLMs:     getenvInt("RETRY_TTL_MS", 30000),
		MaxRetries:     getenvInt("MAX_RETRIES", 5),
		Prefetch:       getenvInt("PREFETCH", 50),
		PGHost:         getenv("PG_HOST", "pgbouncer"),
		PGPort:         getenvInt("PG_PORT", 5432),
		PGUser:         getenv("PG_USER", "postgres"),
		PGPassword:     getenv("PG_PASSWORD", ""),
		PGDatabase:     getenv("PG_DATABASE", "packiot"),
		HealthPort:     getenvInt("HEALTH_PORT", 9101),
		LogLevel:       getenv("LOG_LEVEL", "info"),
	}
	if cfg.AMQPPassword == "" {
		return nil, fmt.Errorf("RABBITMQ_PASSWORD required")
	}
	return cfg, nil
}

func (c *Config) AMQPURL() string {
	return fmt.Sprintf("amqp://%s:%s@%s:%d/",
		c.AMQPUser, c.AMQPPassword, c.AMQPHost, c.AMQPPort)
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
