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
	"encoding/json"
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
	// 10.9 cutover switch: false = MQTT is THE ingest; the nodered wrap
	// publishes into an unbound exchange until cosmetically retired.
	AMQPSourceEnabled bool
	WorkerQueue       string // 'edge-transformer-q' (legacy/catch-all, kept for parity with oeecloud-worker pattern)
	RetryExchange     string // 'plc.normalized-retry'
	RetryQueue        string // 'edge-transformer-q-retry-30s'
	FailedExchange    string // 'plc.normalized-failed'
	FailedQueue       string // 'edge-transformer-q-failed'
	RetryTTLMs        int    // 30000
	MaxRetries        int    // 5

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
	MQTTEnabled   bool
	MQTTBrokerURL string // tcp://mosquitto:1883 or ssl://broker.factory:8883
	MQTTClientID  string // must be unique per subscriber; default: edge-transformer-<hostname>
	MQTTUsername  string
	MQTTPassword  string
	// MQTTStaleThresholdSeconds — seconds of MQTT silence before the
	// subscriber reports degraded. <= 0 disables the idle checks
	// (connection health still enforced). Staging has no live Sparkplug
	// source — set -1 there so /healthz doesn't stay permanently red.
	MQTTStaleThresholdSeconds int

	// ── SparkPlug B Rebirth request (task #31 / ADR-0042) ──────────────────
	// When a stateful consumer (this edge-transformer) restarts, it loses its
	// per-publisher alias table AND the refactored Calc counter baseline. An
	// agent-only edge node (sparkplug-agent) does NOT re-birth on its own
	// (mosquitto + agent stay up across an app-stack deploy → no reconnect →
	// no NBIRTH), so F2/F3 for that line FREEZES from the restart onward. The
	// durable fix: on a sequence gap or NDATA-before-NBIRTH, publish a
	// "Node Control/Rebirth" NCMD to the edge node, which then re-publishes its
	// full NBIRTH and re-seeds us.
	//
	// RequestRebirthEnabled gates the whole behaviour. Default FALSE →
	// flags-off is exactly the current (frozen-on-restart) behaviour; enabling
	// it is the point, but we prove it first. Requires MQTT_ENABLED=true.
	RequestRebirthEnabled bool
	// RequestRebirthMinIntervalSeconds throttles requests per edge node so a
	// burst of gapped NDATA can't storm a node with NCMDs (one every N s max).
	RequestRebirthMinIntervalSeconds int

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

	// ── Counters-only OEE mode (Modbus counters-only client class) ─────────
	// Some clients (e.g. CPACK L6, staging ent 3) emit production counters
	// via Modbus but have NO physical speed sensor — no MachSpeed metric ever
	// arrives. The Calc Phase-8 glitch guard `prodSpeed < 3*machSpeed` then
	// rejects every counter (machSpeed=0 → bound 0), yielding zero OEE. When
	// this mode is on, Calc swaps that guard for a CONFIGURED rated-speed
	// bound for opted-in equipment so counts flow and OEE computes.
	//
	// CountersOnlyEnabled gates the whole feature. Default false → zero
	// behavior change (the per-equipment map is never consulted).
	CountersOnlyEnabled bool
	// CountersOnlyIdealRates maps a Sparkplug UNIT topic (5-segment
	// Enterprise/Site/Area/Line/Unit) to that equipment's configured ideal /
	// rated speed in parts-per-minute — the SAME value CS Admin sets as
	// equipments.production_speed during onboarding (task #13). This env map
	// is the INTERIM edge seam until the edge-transformer can source the rate
	// from refdata or an inbound Parameter30701 metric. Parsed from the JSON
	// env var COUNTERS_ONLY_IDEAL_RATES, e.g.
	//   {"CPACK/SC/LINHAS/L6/MEMBER1":90,"CPACK/SC/LINHAS/L6/MEMBER2":120}
	// An equipment absent from this map is NOT treated as counters-only even
	// when the flag is on (explicit opt-in, never guessed).
	CountersOnlyIdealRates map[string]float64

	// ── Birth-bound routing (ADR-0046 step 1) ─────────────────────────────
	// When ON, counter identity + role are taken from the (N/D)BIRTH declaration
	// — properties["counter_role"] + device_key → id_equipment via
	// packml_register — and cached as (edge_node, alias) → (id_equipment, role).
	// On DDATA a bound alias routes DIRECTLY to Calc with NO metric-name string
	// parsing; an unbound alias fails closed (rebirth + drop, ADR-0042). OFF
	// (default) keeps the legacy string-parse path byte-identical — a no-op
	// deploy. Mirrors the SHADOW_EMIT_*/CALC_CUTOVER_* reversible-flip discipline.
	BirthBoundRouting bool
	// BirthBoundDeviceMap is the operator-supplied device_key → id_equipment
	// resolver used by the birth binder. It is the INTERIM edge seam (like
	// COUNTERS_ONLY_IDEAL_RATES) until edge-transformer can resolve device_key
	// against packml_register directly — the transformer has no DB pool today,
	// and the current packml_register keys on packml_topic (slash-delimited),
	// NOT the ADR-0046 device_key (hyphen-delimited), so no automatic mapping is
	// invented here. Parsed from JSON env BIRTH_BOUND_DEVICE_MAP, e.g.
	//   {"CPACK-SC-LINHAS-L5":40004,"CPACK-SC-LINHAS-L5-BREYER":40010}
	// A device_key absent from this map does NOT resolve → its counters fail
	// closed (explicit config, never guessed).
	BirthBoundDeviceMap map[string]int

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

	// EmitLivenessTimeoutSeconds is the #91 shadowpub emit-liveness window: if
	// the publisher is actively attempting but has had zero broker confirms for
	// this long, /healthz goes 503 so orchestration recycles the silently-stalled
	// service (the #89 gap). 0 disables the check. See shadowpub.DefaultLivenessTimeout.
	EmitLivenessTimeoutSeconds int

	// ── Edge command channel (ADR-0019 C1 / task G4) ──────────────────────
	// The RETURN path: an operator action in the cloud writes a value DOWN
	// to the PLC (SparkPlug DCMD). This is the ONLY machine-write path in
	// the stack, so it ships gated + inert. See docs/adr/reference/designs/
	// 0019-C1-edge-command-channel.md.
	//
	// CommandsEnabled gates the WHOLE path — like MQTT_ENABLED and the uns
	// deriver, the consumer only starts when this is true. Default false so
	// the transformer ships with zero behavior change; a machine-write path
	// must be opt-in, never on-by-accident.
	CommandsEnabled bool
	// CommandsAllowed is the allow-list of verbs the executor will translate
	// to a PLC write. A verb NOT in this set is REJECTED (ack rejected + DLX),
	// never guessed. Default "po_setup,param_write" mirrors the ADR-0019
	// capabilities.commands.allowed contract.
	CommandsAllowed []string
	// CommandsExchange is the topic exchange operator commands land on. The
	// per-tenant queue `edge-commands-<tenant>-q` binds `edge.commands.<tenant>`;
	// acks publish back to `edge.commands.<tenant>.ack` on the same exchange.
	CommandsExchange string
	// CommandsQueuePrefix is the per-tenant queue base name. Final queue is
	// `<prefix>-<tenant>-q` (+ `-retry-30s` / `-failed` for the DLX triple).
	CommandsQueuePrefix string
	// CommandsRetryExchange / CommandsFailedExchange complete the retry/DLX
	// triple, mirroring the ingest topology's shape.
	CommandsRetryExchange  string
	CommandsFailedExchange string
	// CommandsEdgeNode is the SparkPlug edge-node id the DCMD is published
	// under: `spBv1.0/<group>/DCMD/<edgeNode>`. Group is derived from the
	// command's packmlTopic first segment; the edge node is deployment-fixed
	// (the plc-sim's node id in staging).
	CommandsEdgeNode string
	// CommandsDedupCap bounds the in-memory idempotency-key set (FIFO
	// eviction). Re-delivery of a seen key does NOT re-issue the DCMD.
	CommandsDedupCap int
}

func Load() (*Config, error) {
	mode := Mode(strings.ToLower(getenv("EDGE_TRANSFORMER_MODE", string(ModeFactory))))
	switch mode {
	case ModeFactory, ModeDevReplay:
	default:
		return nil, fmt.Errorf("EDGE_TRANSFORMER_MODE=%q: must be one of [factory dev_replay]", mode)
	}

	return &Config{
		Mode:              mode,
		AWSRegion:         getenv("AWS_REGION", "us-east-1"),
		RabbitMQSecretID:  getenv("RABBITMQ_SECRET_ID", "packiot/staging/rabbitmq-edge-transformer-creds"),
		AMQPHost:          getenv("RABBITMQ_HOST", "rabbitmq"),
		AMQPPort:          getenvInt("RABBITMQ_PORT", 5672),
		SourceExchange:    getenv("SOURCE_EXCHANGE", "plc.normalized"),
		AMQPSourceEnabled: getenv("AMQP_SOURCE_ENABLED", "true") == "true",
		WorkerQueue:       getenv("WORKER_QUEUE", "edge-transformer-q"),
		RetryExchange:     getenv("RETRY_EXCHANGE", "plc.normalized-retry"),
		RetryQueue:        getenv("RETRY_QUEUE", "edge-transformer-q-retry-30s"),
		FailedExchange:    getenv("FAILED_EXCHANGE", "plc.normalized-failed"),
		FailedQueue:       getenv("FAILED_QUEUE", "edge-transformer-q-failed"),
		RetryTTLMs:        getenvInt("RETRY_TTL_MS", 30000),
		MaxRetries:        getenvInt("MAX_RETRIES", 5),
		Prefetch:          getenvInt("PREFETCH", 50),
		HealthPort:        getenvInt("HEALTH_PORT", 9102),
		LogLevel:          getenv("LOG_LEVEL", "info"),
		ClientYAMLPath:    getenv("CLIENT_YAML_PATH", "/etc/packiot/client.yaml"),

		// MQTT subscriber (ADR-0010 Phase 2 — off by default for safety)
		MQTTEnabled:               getenvBool("MQTT_ENABLED", false),
		MQTTBrokerURL:             getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"),
		MQTTClientID:              getenv("MQTT_CLIENT_ID", "edge-transformer"),
		MQTTUsername:              getenv("MQTT_USERNAME", ""),
		MQTTPassword:              getenv("MQTT_PASSWORD", ""),
		MQTTStaleThresholdSeconds: getenvInt("MQTT_STALE_THRESHOLD_SECONDS", 60),

		// SparkPlug B Rebirth request (task #31 — off by default; prove then enable)
		RequestRebirthEnabled:            getenvBool("ET_REQUEST_REBIRTH_ENABLED", false),
		RequestRebirthMinIntervalSeconds: getenvInt("ET_REQUEST_REBIRTH_MIN_INTERVAL_SECONDS", 30),

		// ADR-0010 Phase 3 port (shadow mode — no behavior change)
		UseGoPort: getenvBool("USE_GO_PORT", false),

		// Counters-only OEE mode (default OFF — no behavior change)
		CountersOnlyEnabled:    getenvBool("COUNTERS_ONLY_OEE_ENABLED", false),
		CountersOnlyIdealRates: getenvFloatMap("COUNTERS_ONLY_IDEAL_RATES"),

		// ADR-0046 step 1 birth-bound routing (default OFF — no behavior change)
		BirthBoundRouting:   getenvBool("BIRTH_BOUND_ROUTING", false),
		BirthBoundDeviceMap: getenvIntMap("BIRTH_BOUND_DEVICE_MAP"),

		// ADR-0011 P2 outbox
		OutboxEnabled: getenvBool("OUTBOX_ENABLED", false),
		OutboxPath:    getenv("OUTBOX_PATH", "/var/lib/edge-transformer/outbox.db"),
		OutboxCap:     getenvInt("OUTBOX_CAP", 100000),

		EmitLivenessTimeoutSeconds: getenvInt("EMIT_LIVENESS_TIMEOUT_SECONDS", 120),

		// ADR-0019 C1 edge command channel (machine-write path — inert by default)
		CommandsEnabled:        getenvBool("EDGE_COMMANDS_ENABLED", false),
		CommandsAllowed:        getenvList("EDGE_COMMANDS_ALLOWED", "po_setup,param_write"),
		CommandsExchange:       getenv("EDGE_COMMANDS_EXCHANGE", "edge.commands"),
		CommandsQueuePrefix:    getenv("EDGE_COMMANDS_QUEUE_PREFIX", "edge-commands"),
		CommandsRetryExchange:  getenv("EDGE_COMMANDS_RETRY_EXCHANGE", "edge.commands-retry"),
		CommandsFailedExchange: getenv("EDGE_COMMANDS_FAILED_EXCHANGE", "edge.commands-failed"),
		CommandsEdgeNode:       getenv("EDGE_COMMANDS_EDGE_NODE", "plc-sim"),
		CommandsDedupCap:       getenvInt("EDGE_COMMANDS_DEDUP_CAP", 4096),
	}, nil
}

// getenvList parses a comma-separated env var into a trimmed, non-empty
// slice. Falls back to parsing `fallback` (also comma-separated) when the
// var is unset/empty. Used for the command allow-list.
func getenvList(name, fallback string) []string {
	v := os.Getenv(name)
	if v == "" {
		v = fallback
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
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

// getenvFloatMap parses a JSON object of string→number from an env var into
// a map[string]float64. Unset/empty/malformed → an empty (non-nil) map, so
// callers can index safely without a nil check. Used for the counters-only
// per-equipment ideal-rate seam (COUNTERS_ONLY_IDEAL_RATES).
func getenvFloatMap(name string) map[string]float64 {
	out := map[string]float64{}
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return out
	}
	if err := json.Unmarshal([]byte(v), &out); err != nil {
		// Malformed config must not crash boot; return empty so the feature
		// is simply inert (no equipment opted in). Ops see it via the startup
		// log line that reports the parsed entry count.
		return map[string]float64{}
	}
	return out
}

// getenvIntMap parses a JSON object of string→integer from an env var into a
// map[string]int. Unset/empty/malformed → an empty (non-nil) map so callers
// index safely. Used for the birth-bound device_key → id_equipment seam
// (BIRTH_BOUND_DEVICE_MAP).
func getenvIntMap(name string) map[string]int {
	out := map[string]int{}
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return out
	}
	if err := json.Unmarshal([]byte(v), &out); err != nil {
		return map[string]int{}
	}
	return out
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
