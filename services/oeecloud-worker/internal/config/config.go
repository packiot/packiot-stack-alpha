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

	// ConsumeLanes — number of concurrent processing lanes per queue.
	// Deliveries are routed to a lane by hash(source_type) so same-source_type
	// messages stay strictly ordered within a lane (required: po-control
	// lifecycle is read-modify-write) while distinct source_types — which
	// write to disjoint (pool, schema) destinations — process concurrently.
	// 1 (default) = the original single-goroutine serial behavior, so the
	// change is inert until CONSUME_LANES is raised. See consumer.go.
	ConsumeLanes int // 1

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

	// ShadowGoPortEnabled — ADR-0045 G3. Selects the MAIN-POOL background-job
	// flow (see flows.StandardFiltered). DEFAULT TRUE = the F2 comparator
	// layout (staging: jobs run against the `shadow_go_port` schema alongside
	// F1). Set FALSE on a single-flow deployment (new-prod), where the three
	// flows have collapsed to one living in `public` on the main pool: the
	// `shadow_go_port` schema does not exist there, so leaving it enabled makes
	// every background rollup tick error 42P01 (and nothing writes to `public`).
	// When false the jobs target `public` instead. Default-true keeps staging
	// byte-identical.
	ShadowGoPortEnabled bool

	// Pool sizing. The original 5 assumed the ingest consumer runs one query
	// at a time — but the background rollup/refresh jobs (LoopRefresh, bake,
	// grains, uns) share the SAME pools and run concurrently. On the shadow
	// pool a heavy rollup (piot_create_equipment_runtime_1week ~40s+ holding an
	// advisory lock) plus its lock-waiter can consume all 5 connections,
	// starving the equipment_values shadow writes → they time out and fail-open
	// → F3 trickles (2026-07-09). The shadow pool connects DIRECT to the DB EC2
	// (not pgbouncer), so give it headroom; the main pool goes via pgbouncer.
	PGMaxConns       int // main pool (via pgbouncer)
	PGShadowMaxConns int // shadow pool (direct) — needs headroom for rollups + writes

	// ShiftResolverEnabled — ADR-0014 Phase 2. When true, the Go port of
	// piot_set_shift_on_equipment_values() fills id_shift/id_shift_hour/
	// ts_value_production on SHADOW-path equipment_values writes
	// (source_type "go"/"refactored"). Flow 1 keeps the PL/pgSQL trigger
	// during the comparator bake; retire it only after 168h of zero
	// divergence.
	ShiftResolverEnabled bool

	// ShiftFillFolded — ADR-0014 fold rollback flag (DBA rec, hot-path DB
	// writer). When true, the shift columns (id_shift/id_shift_hour/
	// ts_value_production) are written INSIDE the equipment_values UPSERT
	// and the separate BuildShiftFill UPDATE is skipped — halving the
	// per-metric statement count. When false (default), the legacy path
	// runs: upsert WITHOUT shift columns + a separate companion UPDATE.
	// Default-off so we can deploy dark, flip live, and revert by flag
	// (no redeploy) if the 5-builder param-offset fold misbehaves. Only
	// has effect when ShiftResolverEnabled is also true.
	ShiftFillFolded bool

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

	// Sap13ReasonsFromDim — ADR-0039 R5 CONTRACT Step 1 (task #12): when true the
	// sap13 report sources the downtime-reason category vocabulary from the R5
	// dimension (downtime_reason) + junction (equipment_downtime_reason) instead of
	// the equipments.downtime_reasons jsonb. DEFAULT OFF (byte-identical jsonb path).
	// Flip only after row-for-row parity is verified on staging — the jsonb key the
	// report joins on may be 'name' while the dimension label was backfilled from
	// 'description'; confirm labels match before enabling. jsonb NOT dropped this pass.
	Sap13ReasonsFromDim bool

	// ADR-0014 P3a events deriver. DEFAULT OFF — enable 2026-07-09
	// after the shift-bake close-out (one bake at a time).
	EventsDeriverEnabled      bool
	EventsDeriverIntervalMin  int
	EventsExcludedAreas       string // csv int list (prod parity: config, not hardcode)
	EventsExcludedEnterprises string
	// EventsWiderowStateEnterprises — csv enterprise-id list whose tp=1
	// machines write `state` as a wide-row (no StateCurrent leaf topic) and so
	// are invisible to BuildEventMint AND to the native status_type=4 deriver
	// scope. Opting them in here lets the deriver mint their events from
	// ca_discrete_changes_1s directly (ADR-0031 Incoplast/ent4). Empty = off.
	EventsWiderowStateEnterprises string

	// ADR-0010 §10.4 GAP-1 — the CPAC (status_type=0) stop deriver. DARK,
	// DEFAULT OFF. A PARALLEL path to the status_type=4 deriver above: it mints
	// stop/run interval events from COUNT-ACTIVITY silence (the only independent
	// live signal CPACK's edge produces — its `state` is NULL on the live path)
	// into a SHADOW comparison table, so deploying it flag-off is byte-identical.
	// Enablement is gated on the comparator (cpac_deriver_comparator.sql).
	CPACEventDerivationEnabled bool
	CPACEventIntervalMin       int
	CPACEventEnterprises       string // csv int list of status_type=0 enterprises (CPACK=3); empty ⇒ inert
	// CPACStopThresholdDefaultSec — fallback stop horizon when
	// equipments.stop_threshold_time (Parameter 30751) IS NULL/0 (it is NULL for
	// all CPACK equipment on staging). This is THE tuning knob the comparator
	// gates; too tight over-detects count-cadence gaps as stops.
	CPACStopThresholdDefaultSec int
	// CPACEventTargetTable — the shadow comparison table in EvSchema the
	// derivation writes to (default equipment_events_cpac_shadow). Kept separate
	// from equipment_events (owned by the mirror fan-out + operators for CPACK)
	// so the comparator is a clean two-table diff and flag-off parity is total.
	CPACEventTargetTable string

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
	PORecalcEnabled               bool
	PORecalcIntervalMinutes       int
	PORecalcWindow                string // prod: '1 month'
	PORecalcExcludedEnterprises   string // prod: 6 (owned by its sync chain)
	RuntimeProvisionEnabled       bool
	RuntimeProvisionIntervalHours int // provision cadence; 30-day horizon makes hourly wasteful (default 6)
	RuntimeRollupEnabled          bool
	// DQAlarmsEnabled — north-star P11 (andon) Tier-0 data-quality alarm substrate.
	// When true, the rollup tick DETECTS data-quality violations (oee>1, net>gross,
	// negatives, ideal_speed=0-while-producing) on each computed grain and RECORDS a
	// data_quality_event (pure side-write; NO served value is altered). Default true
	// on staging; flip off to disable detection entirely (reversible).
	DQAlarmsEnabled bool
	// SilverClampEnabled — ADR-0036 §4 Silver invariant layer. When true, a
	// dedicated pass runs AFTER the grain rollups each tick and ENFORCES the domain
	// invariants on the served Gold rows (0≤oee,oee_a,oee_p,oee_q≤1; net≤gross via
	// scrap=GREATEST(gross-net,0); non-negative counts/durations), clamping any
	// out-of-range value to its bound. Every clamp that CHANGES a value is paired
	// with an INVARIANT_CLAMPED_* data_quality_event (never silent). No-op on clean
	// rows (WHERE only selects genuine violators → zero writes → byte-identical, so
	// the F2↔F3 identity comparator holds). Default true on staging; reversible.
	SilverClampEnabled bool
	// Backfill drains recalc_needed hour rows stranded OUTSIDE the live rollup's
	// 65-min window (bounded per tick, oldest-first). Both original blockers are
	// now solved: the shadow cagg scheduler self-heal made the widened join fast
	// (53s → 0.7s), and the advisory lock is now non-blocking (pg_try_...), so
	// the main-pool 120s timeout can't bite. On by default with the live rollup.
	RollupBackfillEnabled bool
	// RefSync mirrors master/reference tables (equipments, packml_register,
	// production_targets, products, clients, …) main→packiot_shadow so F3 rollups
	// read the same reference plane as F2 (the F2/F3 identity requirement). Runs
	// only when the shadow DB is configured.
	RefSyncEnabled                bool
	RefSyncIntervalMinutes        int
	RollupBackfillLimit           int // hour rows recomputed per backfill tick
	RollupBackfillIntervalSeconds int
	RollupShiftLimit              int // shift rows recomputed per live rollup tick (bounds the tx so it can't roll back wholesale under load)
	BakeComparatorEnabled         bool
	// BakeEnterpriseIDs — CSV of enterprises the surface-parity bake runs
	// per tenant. The FIRST id is the frozen "gate" tenant (CPACK) whose
	// queries run verbatim; the rest are positively scoped. Default "3"
	// keeps behaviour byte-identical until Incoplast (4) is added: "3,4".
	BakeEnterpriseIDs             string
	LegacyIngestEnabled           bool   // false at 10.9 cutover: plc-sim triple-emit replaces the nodered legacy leg
	RollupMachineLevelEnterprises string // prod: 6 (client-6 machines join the shift grain)

	// TenantAllowlist — declarative environment scoping for tenant discovery.
	// tenants.DiscoverActive() reads the MAIN packiot DB's packml_register,
	// but on staging every prod→staging re-cut drags in foreign-tenant
	// register rows, so the worker would declare a queue-triple per tenant
	// (~39 queues for 13 tenants) when staging only owns cpack + sbxcpack.
	// When non-empty, discovered tenants are intersected with this list so
	// "staging = these tenants only" is a config invariant that survives the
	// next re-cut. EMPTY/UNSET = allow ALL — the production default, no
	// behavior change. Sourced from WORKER_TENANT_ALLOWLIST (comma-separated;
	// each entry lowercased + trimmed, mirroring the group_id normalization
	// in tenants.DiscoverActive).
	TenantAllowlist []string

	// POControlEnabled — ADR-0010 10.3 slice 1 (30800-30803 lifecycle).
	// OFF until synthetic-inject verification (staging has no live
	// 30800 traffic; see the port design doc).
	POControlEnabled bool

	// ── Counters-only Availability fallback (state-less Modbus machines) ──
	// Follow-up to the counters-only OEE mode (PR #591). #591 lets a
	// speed-sensorless machine compute PERFORMANCE from counts against a
	// configured rated speed. But AVAILABILITY = running_time / planned_time
	// is derived from StateCurrent/downtime events, so a machine that is
	// counters-only AND emits NO state has no availability basis
	// (running_time stays 0 → oee_a 0). When enabled, the hour + shift
	// rollups INFER running-vs-stopped from COUNT ACTIVITY for opted-in
	// equipment whose bucket carried no state events: a bucket is "running"
	// while its counter advanced within the idle timeout, "stopped/idle"
	// otherwise. Availability = active-count-time / planned-time.
	//
	// Default OFF → byte-identical rollup (the fallback pass is never
	// appended to the statement stream). Auto-engages per bucket only when
	// BOTH hold: (1) the id_equipment is in CountersOnlyAvailEquipments
	// (explicit opt-in — the rollup-side analog of #591's per-equipment
	// COUNTERS_ONLY_IDEAL_RATES seam), and (2) the bucket has no state events
	// (hour: still flagged after phase E; shift: absent from shift_ev).
	// State-driven Availability is left untouched for machines with state.
	CountersOnlyAvailEnabled        bool
	CountersOnlyAvailEquipments     string // CSV of id_equipment (config.CSVInts)
	CountersOnlyAvailIdleTimeoutSec int    // grace secs after last count before "stopped"

	// Line-from-lead derivation (line-metered counter-only clients): tp=3 lines
	// in these enterprises derive gross/net/availability from their designated
	// lead_machine's cagg. Mutually exclusive with the counters-only fallback
	// per client. Reuses CountersOnlyAvailIdleTimeoutSec for the sessionization.
	CountersOnlyLineLeadEnabled     bool
	CountersOnlyLineLeadEnterprises string // CSV of id_enterprise

	// ── Increment sanity clamp (ADR-0037 Silver invariant) ───────────────
	// When enabled, the equipment_values writer rejects any production
	// increment (Processed/Consumed/Defective delta) that exceeds
	// K · equipments.production_speed · Δt — a physically-impossible count
	// for a machine at its rated speed since the last reading. The rejected
	// increment is written as 0 and recorded as a data_quality_event
	// (INVARIANT_CLAMPED_INCREMENT). Default OFF → byte-identical writes.
	// Defends the cagg SUM against double-source / reordered-sample phantoms
	// (e.g. plc-sim + real-agent feeding one topic with different totalizer
	// origins). K defaults 4; MinDt floors Δt (secs) so a sub-interval burst
	// can't collapse the bound.
	IncrementSanityClampEnabled  bool
	IncrementSanityClampK        float64
	IncrementSanityClampMinDtSec int
	// IncrementSanityClampSpikeFloor is the rate-INDEPENDENT backstop for the
	// ADR-0045 P1 first-boot spike: an increment that consumes the whole
	// absolute totalizer (value >= absolute) with absolute >= this floor is a
	// delta-from-zero artifact and is rejected even with no configured rated
	// speed (the counters-only line-lead path) and on the first sample after a
	// worker restart. Defaults to 1000 parts.
	IncrementSanityClampSpikeFloor float64

	// ── Provisional ideal-speed inference (counters-only, no nameplate) ──
	// Sibling of the counters-only OEE mode (#591): #591 gives a
	// speed-sensorless machine a CONFIGURED rated speed to compute Performance
	// from counts; this task DISCOVERS a provisional one from history for a
	// tenant (bispharma) that has neither PLC param 30701 nor a nameplate, so
	// equipments.production_speed is NULL and the rollup's ideal_speed COALESCE
	// chain (hour.go/shift.go end in equipments.production_speed) can't compute
	// oee_p. When enabled, an hourly loop infers production_speed for opted-in
	// tp=3 lines from the p95 of observed per-minute good-count throughput
	// (ca_agg_equipment_values_1min.gross_production_incr) over a trailing
	// window, filling ONLY NULL-or-'inferred' rows (never a client-confirmed
	// nameplate — see the production_speed_source marker + db/init/04 migration).
	//
	// Default OFF → no goroutine, zero statements, byte-identical rollup. See
	// internal/rollup/inferspeed.go for the estimator + guardrail derivation.
	// engaged() requires Enabled && at least one opted-in id_equipment.
	ProvisionalSpeedEnabled     bool
	ProvisionalSpeedEquipments  string  // CSV of id_equipment (opted-in tp=3 lines; config.CSVInts)
	ProvisionalSpeedWindowHours int     // trailing observation window (default 72)
	ProvisionalSpeedMinMinutes  int     // require >= this many productive minutes before writing (default 240)
	ProvisionalSpeedPercentile  float64 // percentile_cont fraction (default 0.95)
	ProvisionalSpeedFloor       float64 // skip if the percentile < this (default 1.0)

	// ── Bronze raw append (ADR-0036 B1 medallion dual-write) ─────────────
	// When enabled, ALONGSIDE each merged equipment_values UPSERT (and each
	// equipment_events mint) the writer ALSO appends the raw sample to the
	// immutable Bronze landing zone (equipment_values_raw / equipment_events_raw)
	// with NO ON CONFLICT (every sample kept as its own source_seq row) and NO
	// sub-second truncation (original precision retained). The merged UPSERT is
	// unchanged — Bronze is a pure side-append. Default OFF → the raw INSERT is
	// never queued, so behavior is byte-identical (the F2↔F3 identity comparator
	// holds). Enable only where the *_raw hypertables exist in the target
	// schema/DB (currently packiot_shadow.public) — a separate gated step.
	BronzeRawAppend bool
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
		ConsumeLanes:                     getenvInt("CONSUME_LANES", 1),
		HealthPort:                       getenvInt("HEALTH_PORT", 9101),
		LogLevel:                         getenv("LOG_LEVEL", "info"),
		PGShadowDBName:                   getenv("POSTGRES_SHADOW_DB_NAME", ""),
		ShadowGoPortEnabled:              getenv("SHADOW_GO_PORT_ENABLED", "true") == "true",
		PGMaxConns:                       getenvInt("POSTGRES_MAX_CONNS", 5),
		PGShadowMaxConns:                 getenvInt("POSTGRES_SHADOW_MAX_CONNS", 15),
		ShiftResolverEnabled:             getenv("SHIFT_RESOLVER_ENABLED", "false") == "true",
		ShiftFillFolded:                  getenv("SHIFT_FILL_FOLDED", "false") == "true",
		Speed33ReportEnabled:             getenv("SPEED33_REPORT_ENABLED", "false") == "true",
		Speed33IntervalMinutes:           getenvInt("SPEED33_INTERVAL_MINUTES", 10),
		Speed33CustomerID:                getenvInt("SPEED33_CUSTOMER_ID", 33),
		Shift06ReportEnabled:             getenv("SHIFT06_REPORT_ENABLED", "false") == "true",
		Shift06IntervalMinutes:           getenvInt("SHIFT06_INTERVAL_MINUTES", 15),
		Shift06CustomerID:                getenvInt("SHIFT06_CUSTOMER_ID", 6),
		Sap13ReportEnabled:               getenv("SAP13_REPORT_ENABLED", "false") == "true",
		Sap13IntervalMinutes:             getenvInt("SAP13_INTERVAL_MINUTES", 15),
		Sap13CustomerID:                  getenvInt("SAP13_CUSTOMER_ID", 13),
		Sap13ReasonsFromDim:              getenv("SAP13_REASONS_FROM_DIM", "false") == "true",
		EventsDeriverEnabled:             getenv("EVENTS_DERIVER_ENABLED", "false") == "true",
		EventsDeriverIntervalMin:         getenvInt("EVENTS_DERIVER_INTERVAL_MINUTES", 1),
		EventsExcludedAreas:              getenv("EVENTS_EXCLUDED_AREAS", ""),
		EventsExcludedEnterprises:        getenv("EVENTS_EXCLUDED_ENTERPRISES", ""),
		EventsWiderowStateEnterprises:    getenv("EVENTS_WIDEROW_STATE_ENTERPRISES", ""),
		CPACEventDerivationEnabled:       getenv("CPAC_EVENT_DERIVATION_ENABLED", "false") == "true",
		CPACEventIntervalMin:             getenvInt("CPAC_EVENT_DERIVATION_INTERVAL_MINUTES", 1),
		CPACEventEnterprises:             getenv("CPAC_EVENT_ENTERPRISES", ""),
		CPACStopThresholdDefaultSec:      getenvInt("CPAC_STOP_THRESHOLD_DEFAULT_SEC", 300),
		CPACEventTargetTable:             getenv("CPAC_EVENT_TARGET_TABLE", "equipment_events_cpac_shadow"),
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
		RuntimeProvisionIntervalHours:    getenvInt("RUNTIME_PROVISION_INTERVAL_HOURS", 6),
		RuntimeRollupEnabled:             getenv("RUNTIME_ROLLUP_ENABLED", "false") == "true",
		DQAlarmsEnabled:                  getenv("DQ_ALARMS_ENABLED", "true") == "true",
		SilverClampEnabled:               getenv("SILVER_CLAMP_ENABLED", "true") == "true",
		RollupBackfillEnabled:            getenv("ROLLUP_BACKFILL_ENABLED", "true") == "true",
		RefSyncEnabled:                   getenv("REFSYNC_ENABLED", "true") == "true",
		RefSyncIntervalMinutes:           getenvInt("REFSYNC_INTERVAL_MINUTES", 5),
		RollupBackfillLimit:              getenvInt("ROLLUP_BACKFILL_LIMIT", 200),
		RollupShiftLimit:                 getenvInt("ROLLUP_SHIFT_LIMIT", 300),
		RollupBackfillIntervalSeconds:    getenvInt("ROLLUP_BACKFILL_INTERVAL_SECONDS", 30),
		BakeComparatorEnabled:            getenv("BAKE_COMPARATOR_ENABLED", "false") == "true",
		BakeEnterpriseIDs:                getenv("BAKE_ENTERPRISE_IDS", "3"),
		LegacyIngestEnabled:              getenv("LEGACY_INGEST_ENABLED", "true") == "true",
		RollupMachineLevelEnterprises:    getenv("ROLLUP_MACHINE_LEVEL_ENTERPRISES", "6"),
		TenantAllowlist:                  csvLower(getenv("WORKER_TENANT_ALLOWLIST", "")),
		Sync06ReportEnabled:              getenv("SYNC06_REPORT_ENABLED", "false") == "true",
		Sync06IntervalMinutes:            getenvInt("SYNC06_INTERVAL_MINUTES", 15),
		Sync06EnterpriseID:               getenvInt("SYNC06_ENTERPRISE_ID", 6),
		Sync06Target:                     getenv("SYNC06_TARGET", ""),
		Boxes13IntervalMinutes:           getenvInt("BOXES13_INTERVAL_MINUTES", 5),
		// Counters-only Availability fallback (default OFF — no behavior change)
		CountersOnlyAvailEnabled:        getenv("COUNTERS_ONLY_AVAILABILITY_ENABLED", "false") == "true",
		CountersOnlyAvailEquipments:     getenv("COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS", ""),
		CountersOnlyAvailIdleTimeoutSec: getenvInt("COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS", 300),
		CountersOnlyLineLeadEnabled:     getenv("COUNTERS_ONLY_LINE_LEAD_ENABLED", "false") == "true",
		CountersOnlyLineLeadEnterprises: getenv("COUNTERS_ONLY_LINE_LEAD_ENTERPRISES", ""),
		// Increment sanity clamp (default OFF — no behavior change)
		IncrementSanityClampEnabled:    getenv("INCREMENT_SANITY_CLAMP_ENABLED", "false") == "true",
		IncrementSanityClampK:          getenvFloat("INCREMENT_SANITY_CLAMP_K", 4.0),
		IncrementSanityClampMinDtSec:   getenvInt("INCREMENT_SANITY_CLAMP_MIN_DT_SECONDS", 60),
		IncrementSanityClampSpikeFloor: getenvFloat("INCREMENT_SANITY_CLAMP_SPIKE_FLOOR", 1000),
		// Provisional ideal-speed inference (default OFF — no behavior change)
		ProvisionalSpeedEnabled:     getenv("PROVISIONAL_SPEED_INFERENCE_ENABLED", "false") == "true",
		ProvisionalSpeedEquipments:  getenv("PROVISIONAL_SPEED_EQUIPMENTS", ""),
		ProvisionalSpeedWindowHours: getenvInt("PROVISIONAL_SPEED_WINDOW_HOURS", 72),
		ProvisionalSpeedMinMinutes:  getenvInt("PROVISIONAL_SPEED_MIN_MINUTES", 240),
		ProvisionalSpeedPercentile:  getenvFloat("PROVISIONAL_SPEED_PERCENTILE", 0.95),
		ProvisionalSpeedFloor:       getenvFloat("PROVISIONAL_SPEED_FLOOR", 1.0),
		// Bronze raw append (ADR-0036 B1) — default OFF → byte-identical no-op.
		BronzeRawAppend: getenv("BRONZE_RAW_APPEND", "false") == "true",
	}, nil
}

// getenvFloat parses a float env var, falling back on empty/invalid.
func getenvFloat(name string, fallback float64) float64 {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return fallback
	}
	return f
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

// csvLower parses "A, b ,C" into ["a","b","c"] — comma-separated, each
// entry trimmed + lowercased, blanks dropped. Empty/blank input → nil (an
// empty allowlist means "allow ALL", so a nil slice is the correct
// no-scoping default; see Config.TenantAllowlist).
func csvLower(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		p = strings.ToLower(strings.TrimSpace(p))
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
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
