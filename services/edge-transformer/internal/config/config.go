// Package config loads runtime configuration from environment variables.
// Secrets (any future DB password, RabbitMQ password) are NOT in env — they
// are fetched from AWS Secrets Manager by main.go at startup. Same shape
// as services/oeecloud-worker/internal/config.
//
// ADR-0009 Phase 2: this skeleton ships shadow-mode only. Config fields
// already encode the eventual Phase 2 surface (per-tenant queues, DLQ +
// reanimator, dual-mode boot via EDGE_TRANSFORMER_MODE), so adding the real
// handlers in later phases doesn't churn this file.
//
// TODO(ADR-0009 Phase 2): wire EDGE_TRANSFORMER_MODE to actually branch
// boot behavior — `factory` (production runtime against local RabbitMQ)
// vs `dev_replay` (local laptop, consume from a fixture queue). Today both
// modes share identical behavior; only the log line differs.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Mode selects the boot personality. Single binary, two modes — same trick
// as ADR-0007's edge-api `EDGE_API_MODE=cloud_router|factory_local`. The
// reuse rule (ADR-0009 Errata Correction 2) calls this out explicitly.
type Mode string

const (
	ModeFactory   Mode = "factory"
	ModeDevReplay Mode = "dev_replay"
)

type Config struct {
	// Boot personality. See Mode constants.
	Mode Mode

	// AWS Secrets Manager
	AWSRegion        string
	RabbitMQSecretID string // packiot/<env>/rabbitmq-edge-transformer-creds (TBD Phase 2)

	// AMQP — host/port only. Username + password come from Secrets Manager.
	AMQPHost string
	AMQPPort int

	// Source exchange / queue topology. The transformer consumes from
	// `plc.normalized.<tenant>` on the local factory broker. Per-tenant
	// queues follow the same shape as oeecloud-worker's Strategy C
	// Phase 2a topology (one queue per customer, shared Connection,
	// per-tenant Channel via errgroup) — see internal/amqp/topology.go.
	//
	// Reuse rule: do NOT invent a new naming scheme. The `<base>-<tenant>`
	// pattern matches oeecloud-worker's per-tenant queue names verbatim
	// so operator runbooks transfer.
	SourceExchange string // 'plc.normalized'
	WorkerQueue    string // 'edge-transformer-q' (legacy/catch-all, kept for parity with oeecloud-worker pattern)
	RetryExchange  string // 'plc.normalized-retry'
	RetryQueue     string // 'edge-transformer-q-retry-30s'
	FailedExchange string // 'plc.normalized-failed'
	FailedQueue    string // 'edge-transformer-q-failed'
	RetryTTLMs     int    // 30000
	MaxRetries     int    // 5

	// Consumer tuning
	Prefetch int // 50 — bounded outstanding ack count

	// HTTP — :9102 deliberately, to avoid clashing with oeecloud-worker's
	// 9101 when both run on the same host (factory deployments may
	// eventually colocate; staging today already does).
	HealthPort int

	// Logging
	LogLevel string // 'debug' | 'info' | 'warn' | 'error'

	// Path to the per-customer client.yaml (ADR-0009 Phase 1).
	// Mounted into the container; not packaged into the image.
	ClientYAMLPath string

	// ── MQTT subscriber (ADR-0010 Phase 2) ────────────────────────────────
	// Feature-flagged off by default so existing deployments don't get a
	// new failure mode. Set MQTT_ENABLED=true to spawn the subscriber
	// alongside the AMQP consumer.
	//
	// Creds are read from env for the MVP. A follow-up PR will move them
	// to AWS Secrets Manager via a MQTTSecretID field (same shape as
	// RabbitMQSecretID above).
	MQTTEnabled  bool
	MQTTBrokerURL string // tcp://mosquitto:1883 or ssl://broker.factory:8883
	MQTTClientID  string // must be unique per subscriber; default: edge-transformer-<hostname>
	MQTTUsername  string
	MQTTPassword  string

	// UseGoPort — feature flag for ADR-0010 Phase 3. When true, the
	// calc_production_counters Go port runs in SHADOW mode: it evaluates
	// every counter-topic Sparkplug metric against its own State store,
	// logs the Decision + emits Prometheus counters, but does NOT change
	// the shadowpub output. This lets ops compare Go-port state to Node-
	// RED's state via metrics BEFORE the actual cutover (Phase 4).
	//
	// Default false — port is opt-in until the 30-day comparator soak
	// passes.
	UseGoPort bool

	// ADR-0011 P2 outbox — store-and-forward between decode and publish.
	// When enabled, decoded Sparkplug DATA envelopes get written to a
	// SQLite outbox before publishing. A separate drain goroutine
	// publishes to RabbitMQ with confirms + retries. On confirm the row
	// is deleted; on failure it stays for retry.
	//
	// Default false — feature-flagged so we canary the durability
	// upgrade. When ON, the direct-publish path is bypassed entirely.
	OutboxEnabled bool
	OutboxPath    string // filesystem path to the SQLite DB
	OutboxCap     int    // max rows before FIFO drop-oldest kicks in
}

func Load() (*Config, error) {
	mode := Mode(strings.ToLower(getenv("EDGE_TRANSFORMER_MODE", string(ModeFactory))))
	switch mode {
	case ModeFactory, ModeDevReplay:
	default:
		return nil, fmt.Errorf("EDGE_TRANSFORMER_MODE=%q: must be one of [factory dev_replay]", mode)
	}

	return &Config{
		Mode:             mode,
		AWSRegion:        getenv("AWS_REGION", "us-east-1"),
		RabbitMQSecretID: getenv("RABBITMQ_SECRET_ID", "packiot/staging/rabbitmq-edge-transformer-creds"),
		AMQPHost:         getenv("RABBITMQ_HOST", "rabbitmq"),
		AMQPPort:         getenvInt("RABBITMQ_PORT", 5672),
		SourceExchange:   getenv("SOURCE_EXCHANGE", "plc.normalized"),
		WorkerQueue:      getenv("WORKER_QUEUE", "edge-transformer-q"),
		RetryExchange:    getenv("RETRY_EXCHANGE", "plc.normalized-retry"),
		RetryQueue:       getenv("RETRY_QUEUE", "edge-transformer-q-retry-30s"),
		FailedExchange:   getenv("FAILED_EXCHANGE", "plc.normalized-failed"),
		FailedQueue:      getenv("FAILED_QUEUE", "edge-transformer-q-failed"),
		RetryTTLMs:       getenvInt("RETRY_TTL_MS", 30000),
		MaxRetries:       getenvInt("MAX_RETRIES", 5),
		Prefetch:         getenvInt("PREFETCH", 50),
		HealthPort:       getenvInt("HEALTH_PORT", 9102),
		LogLevel:         getenv("LOG_LEVEL", "info"),
		ClientYAMLPath:   getenv("CLIENT_YAML_PATH", "/etc/packiot/client.yaml"),

		// MQTT subscriber (ADR-0010 Phase 2 — off by default for safety)
		MQTTEnabled:   getenvBool("MQTT_ENABLED", false),
		MQTTBrokerURL: getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"),
		MQTTClientID:  getenv("MQTT_CLIENT_ID", "edge-transformer"),
		MQTTUsername:  getenv("MQTT_USERNAME", ""),
		MQTTPassword:  getenv("MQTT_PASSWORD", ""),

		// ADR-0010 Phase 3 port (shadow mode — no behavior change)
		UseGoPort: getenvBool("USE_GO_PORT", false),

		// ADR-0011 P2 outbox
		OutboxEnabled: getenvBool("OUTBOX_ENABLED", false),
		OutboxPath:    getenv("OUTBOX_PATH", "/var/lib/edge-transformer/outbox.db"),
		OutboxCap:     getenvInt("OUTBOX_CAP", 100000),
	}, nil
}

func getenvBool(name string, fallback bool) bool {
	v := strings.ToLower(os.Getenv(name))
	switch v {
	case "":
		return fallback
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
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
