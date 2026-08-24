// Package config loads runtime configuration from environment variables.
// AMQP credentials are NOT in env — they are fetched from AWS Secrets Manager
// by main.go at startup (mirrors services/oeecloud-worker). The fan-out reuses
// the SAME least-privilege `oeecloud-worker` AMQP user secret so it needs no
// new broker principal.
package config

import (
	"os"
	"strconv"
	"strings"
)

type Config struct {
	// Master gate. FALSE (default) → the service starts, serves /health, and
	// idles: it binds NO queue and consumes NOTHING. Staging .env flips this on
	// per twin. Never set in prod compose.
	Enabled bool

	// AWS Secrets Manager (same secret the worker uses).
	AWSRegion        string
	RabbitMQSecretID string

	// AMQP — host/port only; username+password come from Secrets Manager.
	AMQPHost string
	AMQPPort int

	// Exchange the decoded SparkPlug stream flows through (topic). The fan-out
	// binds a queue here on the SOURCE routing key(s) and republishes to it on
	// the TARGET routing key.
	SourceExchange string

	// FanoutQueue is the durable queue this consumer owns, bound to the source
	// routing key(s). Named per twin so many twins coexist.
	FanoutQueue string

	// SourceRoutingKeys are the routing keys the queue binds to. Default
	// ["sparkplug.data", "sparkplug.data.<sourcetenant>"]. The staging
	// edge-transformer publishes the 2-segment `sparkplug.data` by default
	// (tenant rides inside the envelope), so `sparkplug.data` is the live key
	// unless the decoder's F3_PER_TENANT_ROUTING flag is set — when it is, the
	// decoder emits `sparkplug.data.<tenant>` and the 3-segment binding below
	// keeps this fan-out working across that flip. The in-code group filter (retenant.Retenant's
	// `ours`) guarantees only SOURCE-tenant envelopes are cloned regardless of
	// which binding delivered them, so binding the shared key can't leak other
	// tenants into the target.
	SourceRoutingKeys []string

	// TargetRoutingKey is where the re-tenanted clone is republished, e.g.
	// `sparkplug.data.sbxcpack`. Must be a per-tenant (3-segment) key so it is
	// picked up by the target's queue (oeecloud-worker-q-<target>) and does NOT
	// match this consumer's source bindings (no self-feedback loop).
	TargetRoutingKey string

	// Re-tenant transform groups (SparkPlug GroupIDs / first topic segment).
	SourceGroup string // e.g. CPACK
	TargetGroup string // e.g. SBXCPACK

	// Consumer tuning.
	Prefetch int

	// PublishConfirmTimeoutMs bounds the wait for the broker's publish confirm
	// before a republish is treated as failed (→ nack+requeue, retried).
	PublishConfirmTimeoutMs int

	// HTTP health port.
	HealthPort int

	// Logging.
	LogLevel string
}

func Load() *Config {
	sourceGroup := getenv("FANOUT_SOURCE_GROUP", "CPACK")
	targetGroup := getenv("FANOUT_TARGET_GROUP", "SBXCPACK")
	return &Config{
		// Master gate. Generic name for any twin (task #22 — one compose service
		// per twin, each reading its OWN env block, so nothing here needs to be
		// per-pair-named). FANOUT_CPACK_TO_SBXCPACK_ENABLED is kept as a fallback
		// so the already-deployed CPACK→SBXCPACK instance's .env keeps working
		// unchanged — new twins should set FANOUT_ENABLED instead.
		Enabled:                 getenv("FANOUT_ENABLED", getenv("FANOUT_CPACK_TO_SBXCPACK_ENABLED", "false")) == "true",
		AWSRegion:               getenv("AWS_REGION", "us-east-1"),
		RabbitMQSecretID:        getenv("RABBITMQ_SECRET_ID", "packiot/staging/rabbitmq-oeecloud-creds"),
		AMQPHost:                getenv("RABBITMQ_HOST", "rabbitmq"),
		AMQPPort:                getenvInt("RABBITMQ_PORT", 5672),
		SourceExchange:          getenv("SOURCE_EXCHANGE", "oee"),
		FanoutQueue:             getenv("FANOUT_QUEUE", "oeecloud-fanout-cpack-to-sbxcpack"),
		SourceRoutingKeys:       sourceRoutingKeys(sourceGroup),
		TargetRoutingKey:        getenv("FANOUT_TARGET_ROUTING_KEY", "sparkplug.data."+strings.ToLower(targetGroup)),
		SourceGroup:             sourceGroup,
		TargetGroup:             targetGroup,
		Prefetch:                getenvInt("PREFETCH", 50),
		PublishConfirmTimeoutMs: getenvInt("PUBLISH_CONFIRM_TIMEOUT_MS", 5000),
		HealthPort:              getenvInt("HEALTH_PORT", 9102),
		LogLevel:                getenv("LOG_LEVEL", "info"),
	}
}

// sourceRoutingKeys builds the default binding set: the live 2-segment key plus
// the future 3-segment per-tenant key. Overridable wholesale via
// FANOUT_SOURCE_ROUTING_KEYS (comma-separated).
func sourceRoutingKeys(sourceGroup string) []string {
	if v := os.Getenv("FANOUT_SOURCE_ROUTING_KEYS"); v != "" {
		var out []string
		for _, k := range strings.Split(v, ",") {
			if k = strings.TrimSpace(k); k != "" {
				out = append(out, k)
			}
		}
		if len(out) > 0 {
			return out
		}
	}
	return []string{"sparkplug.data", "sparkplug.data." + strings.ToLower(sourceGroup)}
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
