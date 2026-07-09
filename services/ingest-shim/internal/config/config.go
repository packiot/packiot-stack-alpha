// Package config loads runtime configuration from environment variables.
// The RabbitMQ password is NOT in env — it is fetched from AWS Secrets
// Manager by main.go at startup (same CO-5 discipline as oeecloud-worker).
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	// AWS Secrets Manager — where the AMQP username/password live.
	AWSRegion        string
	RabbitMQSecretID string // packiot/staging/rabbitmq-oeecloud-creds

	// AMQP — host/port only; username + password come from Secrets Manager.
	AMQPHost string
	AMQPPort int

	// Publish target. The shim republishes VERBATIM to this existing
	// exchange + routing key — the pair oeecloud-worker consumes.
	Exchange       string        // 'oee' (existing topic exchange)
	RoutingKey     string        // 'sparkplug.data'
	ConfirmTimeout time.Duration // how long to wait for a publisher confirm

	// HTTP.
	HTTPAddr    string // public TLS listener, e.g. ":8444"
	MetricsAddr string // internal plaintext metrics listener, e.g. ":9105"

	// Auth. No default — an empty key would disable auth, so Load() errors
	// out if INGEST_API_KEY is unset.
	IngestAPIKey string

	// Scope guard. Only payloads whose topic/group first segment matches
	// this (case-insensitive) are admitted. Everything else → 403.
	ScopeGroup string // 'INCOPLAST'

	// Body limits.
	MaxBodyBytes int64 // reject empty and > this many bytes

	// TLS. Both required — main refuses to start if either is empty.
	TLSCertFile string
	TLSKeyFile  string

	// Logging.
	LogLevel string
}

// Load reads full config and validates the fields that have no safe
// default (INGEST_API_KEY). TLS files are validated in main so the
// healthcheck path (LoadForHealthcheck) can skip them.
func Load() (*Config, error) {
	c := loadBase()
	if c.IngestAPIKey == "" {
		return nil, fmt.Errorf("INGEST_API_KEY is required (no default — refusing to run with auth disabled)")
	}
	return c, nil
}

// LoadForHealthcheck loads only the fields the `--healthcheck` subcommand
// needs (HTTP_ADDR). It deliberately does NOT require INGEST_API_KEY so the
// Docker healthcheck can run without the secret plumbed into that exec.
func LoadForHealthcheck() (*Config, error) {
	return loadBase(), nil
}

func loadBase() *Config {
	return &Config{
		AWSRegion:        getenv("AWS_REGION", "us-east-1"),
		RabbitMQSecretID: getenv("RABBITMQ_SECRET_ID", "packiot/staging/rabbitmq-oeecloud-creds"),
		AMQPHost:         getenv("RABBITMQ_HOST", "rabbitmq"),
		AMQPPort:         getenvInt("RABBITMQ_PORT", 5672),
		Exchange:         getenv("EXCHANGE", "oee"),
		RoutingKey:       getenv("ROUTING_KEY", "sparkplug.data"),
		ConfirmTimeout:   time.Duration(getenvInt("CONFIRM_TIMEOUT_MS", 5000)) * time.Millisecond,
		HTTPAddr:         getenv("HTTP_ADDR", ":8444"),
		MetricsAddr:      getenv("METRICS_ADDR", ":9105"),
		IngestAPIKey:     os.Getenv("INGEST_API_KEY"),
		ScopeGroup:       getenv("SCOPE_GROUP", "INCOPLAST"),
		MaxBodyBytes:     int64(getenvInt("MAX_BODY_BYTES", 1<<20)), // 1 MiB
		TLSCertFile:      os.Getenv("TLS_CERT_FILE"),
		TLSKeyFile:       os.Getenv("TLS_KEY_FILE"),
		LogLevel:         getenv("LOG_LEVEL", "info"),
	}
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
