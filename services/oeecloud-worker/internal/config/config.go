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
	"strings"
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

	// ShiftResolverEnabled — ADR-0014 Phase 2. When true, the Go port of
	// piot_set_shift_on_equipment_values() fills id_shift/id_shift_hour/
	// ts_value_production on SHADOW-path equipment_values writes
	// (source_type "go"/"refactored"). Flow 1 keeps the PL/pgSQL trigger
	// during the comparator bake; retire it only after 168h of zero
	// divergence.
	ShiftResolverEnabled bool

	// Speed33ReportEnabled — ADR-0012 Wave 2 port #1: the Go-scheduled
	// writer for customer_reports.speed (customer 33). Legacy
	// c33_speed_per_job_insert_into_report keeps the old table on prod;
	// on staging this is the sole writer (legacy never scheduled here).
	Speed33ReportEnabled   bool
	Speed33IntervalMinutes int
	Speed33CustomerID      int
	Shift06ReportEnabled   bool
	Shift06IntervalMinutes int
	Shift06CustomerID      int

	// Sap13ReportEnabled — ADR-0012 Wave 2 port #3: the Go writer for
	// customer_reports.sap_data_sync (customer 13, neopac SAP). Ships
	// DISABLED: enabling is gated on issue #223 (back4-api's
	// data-sync.controller.js must target the pool upsert key first).
	Sap13ReportEnabled   bool
	Sap13IntervalMinutes int
	Sap13CustomerID      int

	// ADR-0014 P3a events deriver. DEFAULT OFF — enable 2026-07-09
	// after the shift-bake close-out (one bake at a time).
	EventsDeriverEnabled      bool
	EventsDeriverIntervalMin  int
	EventsExcludedAreas       string // csv int list (prod parity: config, not hardcode)
	EventsExcludedEnterprises string

	// Sync06ReportEnabled — ADR-0014 P4: enterprise-6 production data
	// sync (verbatim-embedded state machine).
	Sync06ReportEnabled   bool
	Sync06IntervalMinutes int
	Sync06EnterpriseID    int
	Sync06Target          string // empty = legacy table name (verbatim body)

	// Boxes13ReportEnabled — ADR-0014 P4: the Neopac beep-chain
	// aggregator (analogs Label_Neopac → equipment_boxes_cust_13).
	Boxes13ReportEnabled   bool
	Boxes13IntervalMinutes int
	BoxesBridgeEnabled     bool
	UnsRefreshEnabled      bool
	UnsIntervalMinutes     int

	// UnsCurrentMetricsEnabled — the uns_equipment_current_metrics
	// deriver (the table froze post-10.9: its ingest writer's routing
	// key `sparkplug.uns_metrics` lost its only producer). DEFAULT
	// FALSE — ships inert, enabled at the flip. See
	// internal/uns/current_metrics.go for the derivation ledger.
	UnsCurrentMetricsEnabled         bool
	UnsCurrentMetricsIntervalMinutes int

	// PO-runtime refresh dispatcher (P3b: compute → recalc, ordered).
	PORecalcEnabled             bool
	PORecalcIntervalMinutes     int
	PORecalcWindow              string // prod: '1 month'
	PORecalcExcludedEnterprises string // prod: 6 (owned by its sync chain)
	RuntimeProvisionEnabled     bool
	RuntimeRollupEnabled        bool
	BakeComparatorEnabled       bool
	// BakeEnterpriseIDs — CSV of enterprises the surface-parity bake runs
	// per tenant. The FIRST id is the frozen "gate" tenant (CPACK) whose
	// queries run verbatim; the rest are positively scoped. Default "3"
	// keeps behaviour byte-identical until Incoplast (4) is added: "3,4".
	BakeEnterpriseIDs             string
	LegacyIngestEnabled           bool   // false at 10.9 cutover: plc-sim triple-emit replaces the nodered legacy leg
	RollupMachineLevelEnterprises string // prod: 6 (client-6 machines join the shift grain)

	// POControlEnabled — ADR-0010 10.3 slice 1 (30800-30803 lifecycle).
	// OFF until synthetic-inject verification (staging has no live
	// 30800 traffic; see the port design doc).
	POControlEnabled bool
}

func Load() (*Config, error) {
	return &Config{
		AWSRegion:                        getenv("AWS_REGION", "us-east-1"),
		PGSecretID:                       getenv("PG_SECRET_ID", "packiot/staging/db"),
		RabbitMQSecretID:                 getenv("RABBITMQ_SECRET_ID", "packiot/staging/rabbitmq-oeecloud-creds"),
		AMQPHost:                         getenv("RABBITMQ_HOST", "rabbitmq"),
		AMQPPort:                         getenvInt("RABBITMQ_PORT", 5672),
		SourceExchange:                   getenv("SOURCE_EXCHANGE", "oee"),
		WorkerQueue:                      getenv("WORKER_QUEUE", "oeecloud-worker-q"),
		RetryExchange:                    getenv("RETRY_EXCHANGE", "oee-retry"),
		RetryQueue:                       getenv("RETRY_QUEUE", "oeecloud-worker-q-retry-30s"),
		FailedExchange:                   getenv("FAILED_EXCHANGE", "oee-failed"),
		FailedQueue:                      getenv("FAILED_QUEUE", "oeecloud-worker-q-failed"),
		RetryTTLMs:                       getenvInt("RETRY_TTL_MS", 30000),
		MaxRetries:                       getenvInt("MAX_RETRIES", 5),
		Prefetch:                         getenvInt("PREFETCH", 50),
		HealthPort:                       getenvInt("HEALTH_PORT", 9101),
		LogLevel:                         getenv("LOG_LEVEL", "info"),
		PGShadowDBName:                   getenv("POSTGRES_SHADOW_DB_NAME", ""),
		ShiftResolverEnabled:             getenv("SHIFT_RESOLVER_ENABLED", "false") == "true",
		Speed33ReportEnabled:             getenv("SPEED33_REPORT_ENABLED", "false") == "true",
		Speed33IntervalMinutes:           getenvInt("SPEED33_INTERVAL_MINUTES", 10),
		Speed33CustomerID:                getenvInt("SPEED33_CUSTOMER_ID", 33),
		Shift06ReportEnabled:             getenv("SHIFT06_REPORT_ENABLED", "false") == "true",
		Shift06IntervalMinutes:           getenvInt("SHIFT06_INTERVAL_MINUTES", 15),
		Shift06CustomerID:                getenvInt("SHIFT06_CUSTOMER_ID", 6),
		Sap13ReportEnabled:               getenv("SAP13_REPORT_ENABLED", "false") == "true",
		Sap13IntervalMinutes:             getenvInt("SAP13_INTERVAL_MINUTES", 15),
		Sap13CustomerID:                  getenvInt("SAP13_CUSTOMER_ID", 13),
		EventsDeriverEnabled:             getenv("EVENTS_DERIVER_ENABLED", "false") == "true",
		EventsDeriverIntervalMin:         getenvInt("EVENTS_DERIVER_INTERVAL_MINUTES", 1),
		EventsExcludedAreas:              getenv("EVENTS_EXCLUDED_AREAS", ""),
		EventsExcludedEnterprises:        getenv("EVENTS_EXCLUDED_ENTERPRISES", ""),
		POControlEnabled:                 getenv("PO_CONTROL_ENABLED", "false") == "true",
		Boxes13ReportEnabled:             getenv("BOXES13_REPORT_ENABLED", "false") == "true",
		BoxesBridgeEnabled:               getenv("BOXES_BRIDGE_ENABLED", "false") == "true",
		UnsRefreshEnabled:                getenv("UNS_REFRESH_ENABLED", "false") == "true",
		UnsIntervalMinutes:               getenvInt("UNS_INTERVAL_MINUTES", 5),
		UnsCurrentMetricsEnabled:         getenv("UNS_CURRENT_METRICS_ENABLED", "false") == "true",
		UnsCurrentMetricsIntervalMinutes: getenvInt("UNS_CURRENT_METRICS_INTERVAL_MINUTES", 1),
		PORecalcEnabled:                  getenv("PO_RECALC_ENABLED", "false") == "true",
		PORecalcIntervalMinutes:          getenvInt("PO_RECALC_INTERVAL_MINUTES", 1),
		PORecalcWindow:                   getenv("PO_RECALC_WINDOW", "1 month"),
		PORecalcExcludedEnterprises:      getenv("PO_RECALC_EXCLUDED_ENTERPRISES", "6"),
		RuntimeProvisionEnabled:          getenv("RUNTIME_PROVISION_ENABLED", "false") == "true",
		RuntimeRollupEnabled:             getenv("RUNTIME_ROLLUP_ENABLED", "false") == "true",
		BakeComparatorEnabled:            getenv("BAKE_COMPARATOR_ENABLED", "false") == "true",
		BakeEnterpriseIDs:                getenv("BAKE_ENTERPRISE_IDS", "3"),
		LegacyIngestEnabled:              getenv("LEGACY_INGEST_ENABLED", "true") == "true",
		RollupMachineLevelEnterprises:    getenv("ROLLUP_MACHINE_LEVEL_ENTERPRISES", "6"),
		Sync06ReportEnabled:              getenv("SYNC06_REPORT_ENABLED", "false") == "true",
		Sync06IntervalMinutes:            getenvInt("SYNC06_INTERVAL_MINUTES", 15),
		Sync06EnterpriseID:               getenvInt("SYNC06_ENTERPRISE_ID", 6),
		Sync06Target:                     getenv("SYNC06_TARGET", ""),
		Boxes13IntervalMinutes:           getenvInt("BOXES13_INTERVAL_MINUTES", 5),
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

// CSVInts parses "1,2,3" into []int; empty string → empty slice (ANY
// of an empty array matches nothing — exclusions no-op).
func CSVInts(s string) []int {
	out := []int{}
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if n, err := strconv.Atoi(p); err == nil {
			out = append(out, n)
		}
	}
	return out
}
