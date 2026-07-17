// Package config holds runtime config. Most secrets come from AWS Secrets
// Manager at startup (see secrets/), NOT from env vars — that's the CO-5
// improvement vs the TS mirror-worker which read POSTGRES_* / RABBITMQ_*
// via .env interpolation.
package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	AWSRegion string

	// Secret IDs (not the values — values fetched at boot via secrets pkg).
	ProdDBSecretID    string // 'databaseCredentials' — prod awslambda creds (SELECT-only)
	StagingDBSecretID string // 'packiot/staging/db' — staging postgres creds

	// Source identity embedded in DLQ / cursor / mirror_id_map rows.
	// Using 'cpack-prod-go' during parallel-run with the TS mirror-worker
	// (source='cpack-prod') so the two have independent cursors + mappings.
	// Cut over by changing this back to 'cpack-prod' after the TS is stopped.
	SourceName          string
	ProdEnterpriseID    int
	StagingEnterpriseID int

	// Polling cadence + per-row pacing.
	PollIntervalSec int
	BatchSize       int
	PerPostDelayMs  int

	// Staging edge-api — reached on the packiot-net docker network.
	StagingAPIBaseURL string

	// ADR-0012 3-flow parity fan-out for equipment_values deltas.
	// ShadowValueFanout gates the whole feature (shadow_go_port +
	// packiot_shadow writes). ShadowDBName names the Flow 3 database
	// (empty = shadow_go_port only). ShadowDBHost overrides the host for
	// the shadow pool — pgbouncer's static database list doesn't include
	// packiot_shadow, so staging passes the DB EC2 address directly.
	ShadowValueFanout bool
	ShadowDBName      string
	ShadowDBHost      string

	// Event-event interval-overlap matcher thresholds (Phase A4b).
	// EventMinOverlapSec — minimum overlap to count as a match.
	// EventMaxStartDriftSec — staging.ts_event must be no earlier than
	// prod.ts_event - this. Prevents long-stale open staging events
	// (ts_end IS NULL, opened days ago) from matching every later prod
	// event by virtue of the "open window matches everything" overlap.
	EventMinOverlapSec    int
	EventMaxStartDriftSec int

	// HTTP /health server.
	HealthPort int

	// Active-PO reconciliation loop. Closes the ~95% gap left by
	// user_logs-based PO replay: most prod CPACK POs are created by PLC
	// SparkPlug parameter writes (30800–30899) that bypass edge-api's
	// audit middleware, so order-created / order-started rows are rare in
	// user_logs. The reconciler periodically diffs prod active POs vs
	// staging active POs (by id_order) and backfills the missing ones via
	// the same /create + /start endpoints we use in the user_logs handlers.
	ReconcileEnabled     bool
	ReconcileIntervalSec int
	ReconcileMaxPerRun   int

	// Prod-authoritative finisher pass (task #48). The create/revive
	// reconciler above is CREATE-ONLY: it opens/keeps staging POs active to
	// mirror prod's status=2 set, but never CLOSES one. When a prod PO ends
	// via a SparkPlug stop that bypasses edge-api's user_logs (~95% of
	// stops), the mirror never sees an order-stopped, prod's row leaves
	// status=2, and the create-only reconciler simply stops tracking it —
	// leaving the staging mirror stuck at status=2 with an open runtime
	// segment forever (the PO-17106 zombie pattern).
	//
	// The finisher closes that gap: it computes the INVERSE set —
	// mirror-managed staging POs that are status=2 but whose id_order is
	// NO LONGER in prod's status=2 set — cross-checks each against prod
	// authoritatively, and finishes the genuinely-orphaned ones at their
	// prod last-activity ts (NOT now(), to avoid injecting phantom
	// stopped_time). Ships INERT (default false) so it lands as a no-op and
	// is enabled deliberately after review — same discipline as the rest of
	// the migration.
	//
	// ReconcileFinisherGraceMinutes guards against racing a legitimate
	// re-activation: a PO whose prod last-activity is within this window is
	// treated as possibly mid-transition / flapping and skipped this pass.
	ReconcileFinisherEnabled      bool
	ReconcileFinisherGraceMinutes int

	// Value-sync layer. The existence pass (above) tracks which POs are
	// active. The value pass tracks WHAT they show: production_real,
	// gross_production, net_production, qt_stops, OEE rollups. Without
	// this, staging POs would display simulator-driven counters because
	// staging's per-minute pg_cron (piot_proc_refresh_runtime) recomputes
	// production_orders_runtime from staging's simulator-generated
	// equipment_values. The cron will overwrite our UPDATEs within 60 s,
	// so we sync at 30 s — values briefly diverge between syncs but snap
	// back to prod-correct on every reconciler tick.
	//
	// ReconcileValuesEnabled defaults TRUE — without it the existence
	// pass alone leaves staging POs showing simulator counter values
	// indistinguishable from a healthy run, which is misleading for
	// CS / QA reviews.
	ReconcileValuesEnabled     bool
	ReconcileValuesIntervalSec int

	// Events-sync layer. The interval-overlap matcher (translate.EquipmentEvent)
	// can only match if staging has an equipment_event row that overlaps the
	// prod event's interval. After PR #75 made the value-sync the sole writer
	// of CPACK equipment_values (writing NULL state/mode/speed), the
	// piot_set_event trigger pipeline stopped producing equipment_events for
	// CPACK machines — so the matcher started failing on every operator
	// action (event-justified/edited/splitted), DLQ-ing 28 rows by 2026-06-26.
	//
	// This loop mirrors prod equipment_events directly into staging with a
	// mirror_id_map entry, so the matcher's cache hit path takes over and
	// no overlap math is needed. Sole-writer invariant for CPACK
	// equipment_events on staging.
	ReconcileEventsEnabled     bool
	ReconcileEventsIntervalSec int
	ReconcileEventsBatchSize   int

	// Event close-sweep (task #63). Replaces the old prod-ts_event-bounded
	// close re-fan (FetchRecentlyClosedEvents) — which missed any close that
	// landed outside a 48h / 400k-PK window, leaving shadow rows OPEN
	// forever and inflating F2/F3 duration+availability while COUNT parity
	// still passed. The sweep is DRIVEN FROM THE SHADOW instead: it selects
	// the tiny set of divergent shadow rows (ts_end IS NULL at ANY age, or
	// ts_event within the recent window) and re-points each at prod's
	// authoritative (ts_end, status, duration). Cost is O(divergent rows),
	// not O(prod volume).
	//
	// EveryNTicks: cadence in events-sync ticks (a close only needs to land
	//   within the bake drift window, not every tick).
	// RecentHours: RISK-2 recent-close-drift lookback on shadow ts_event.
	// TimeoutSec: hard ctx watchdog around one sweep (candidate fetch +
	//   prod point-lookups + fan-out corrections) — same watchdog discipline
	//   the old FetchRecentlyClosedEvents used to bound a runaway scan.
	// BatchSize: PK page size for the shadow candidate iteration.
	ReconcileEventsCloseSweepEnabled     bool
	ReconcileEventsCloseSweepEveryNTicks int
	ReconcileEventsCloseSweepRecentHours int
	ReconcileEventsCloseSweepTimeoutSec  int
	ReconcileEventsCloseSweepBatchSize   int

	// DLQ retry loop. Periodically re-runs the dispatcher on
	// mirror_replay_dlq rows whose backoff window has elapsed. Drains
	// transient failures (connection refused during a deploy, prod
	// race conditions) without human intervention. Bounded by
	// DLQRetryMaxAttempts so permanent failures stay in DLQ for
	// inspection rather than churning forever.
	//
	// Backoff schedule = (1 << retry_attempts) minutes: 1, 2, 4, 8, 16
	// → ~31 minutes of retry coverage total per row over 5 attempts.
	// Tunable via env if a noisy edge-api forces a wider window.
	DLQRetryEnabled     bool
	DLQRetryIntervalSec int
	DLQRetryMaxAttempts int
	DLQRetryBatchSize   int

	// DLQ reanimator loop. Periodically resets retry_attempts=0 on DLQ
	// rows that exhausted the retry cap but became *newly mappable*
	// because the events reconciler caught up to their underlying prod
	// equipment_event ID. Solves the cohort that lands in DLQ during
	// the events reconciler's cold-start backlog: row is DLQ'd via the
	// interval-overlap fallback before the reconciler has mirrored the
	// matching prod event, retry loop fires 5 times all failing the
	// same way, retry_attempts hits the cap, row sits forever — even
	// though by the time the reconciler catches up the entry would
	// translate fine. The reanimator re-arms only those entries whose
	// translation would now succeed (predicate: prod_id present in
	// mirror_id_map), leaving genuinely-broken rows in their cap state
	// for human triage.
	//
	// Cadence is long-ish (default 10 min) because the trigger event
	// (reconciler crossing a stuck prod_id) happens on the scale of
	// hours/days, not seconds.
	DLQReanimateEnabled     bool
	DLQReanimateIntervalSec int
	DLQReanimateBatchSize   int

	// Comparator loop — fidelity watchdog (ADR-0008 phase 2a). Periodically
	// SELECTs canonical values from BOTH prod and staging, computes
	// divergence, emits Prometheus gauges. SELECT-only on both sides — never
	// mutates either system. Honours the prod-db-select-only discipline by
	// design (the entire pattern is observability, not reconciliation).
	//
	// Phase 2a.1 (this commit) ships the skeleton + the cheapest metric:
	// comparator_active_pos_diff (count diff on production_orders WHERE
	// status=2, scoped per-enterprise). Future metrics (events_lag_seconds,
	// oee_divergence_pct, dlq_anomaly_total, user_logs_lag) land in 2a.2-2a.5
	// without further config plumbing — they re-use this loop's cadence.
	//
	// Cadence default 5 min matches RECONCILE_INTERVAL_SEC — the comparator
	// pairs naturally with the existence reconciler's cycle (active POs is
	// what both touch). Heavier per-PO metrics (OEE divergence) will run on
	// a longer interval handled internally by RunOnce, not a separate loop.
	ComparatorEnabled     bool
	ComparatorIntervalSec int

	// OEE divergence runs at its own (longer) cadence inside the comparator
	// loop. The underlying prod data (production_orders_runtime) is
	// pg_cron-refreshed at ~1-min intervals, so sub-minute sampling reads
	// mid-update; 30 min smooths over a full handful of refresh cycles.
	// Independent of ComparatorIntervalSec — the comparator tick fires
	// every COMPARATOR_INTERVAL_SEC, but the OEE measure only runs every
	// COMPARATOR_OEE_INTERVAL_SEC (gated internally by lastOEERun).
	ComparatorOEEIntervalSec int

	// ComparatorEventOpenStrandHours — close-field parity threshold (task
	// #63). The comparator counts shadow equipment_events rows still OPEN
	// (ts_end IS NULL) whose ts_event is OLDER than this many hours, per
	// plane, and emits them + their f2/f3 skew. Older-than avoids counting
	// legitimately-open live events; a real strand is one that should have
	// closed long ago. Default 48h.
	ComparatorEventOpenStrandHours int

	// Logging.
	LogLevel string
}

func Load() (*Config, error) {
	cfg := &Config{
		AWSRegion:             getenv("AWS_REGION", "us-east-1"),
		ProdDBSecretID:        getenv("PROD_DB_SECRET_ID", "databaseCredentials"),
		StagingDBSecretID:     getenv("STAGING_DB_SECRET_ID", "packiot/staging/db"),
		SourceName:            getenv("SOURCE_NAME", "cpack-prod-go"),
		ProdEnterpriseID:      getenvInt("PROD_ENTERPRISE_ID", 1),
		StagingEnterpriseID:   getenvInt("STAGING_ENTERPRISE_ID", 3),
		PollIntervalSec:       getenvInt("POLL_INTERVAL_SEC", 60),
		BatchSize:             getenvInt("BATCH_SIZE", 50),
		PerPostDelayMs:        getenvInt("PER_POST_DELAY_MS", 50),
		StagingAPIBaseURL:     getenv("STAGING_API_URL", "http://edge-api:8080"),
		ShadowValueFanout:     getenvBool("SHADOW_VALUE_FANOUT", false),
		ShadowDBName:          getenv("POSTGRES_SHADOW_DB_NAME", ""),
		ShadowDBHost:          getenv("SHADOW_DB_HOST", ""),
		EventMinOverlapSec:    getenvInt("EVENT_MIN_OVERLAP_SEC", 30),
		EventMaxStartDriftSec: getenvInt("EVENT_MAX_START_DRIFT_SEC", 600),
		HealthPort:            getenvInt("HEALTH_PORT", 9102),
		ReconcileEnabled:      getenvBool("RECONCILE_ENABLED", true),
		ReconcileIntervalSec:  getenvInt("RECONCILE_INTERVAL_SEC", 300),
		ReconcileMaxPerRun:    getenvInt("RECONCILE_MAX_PER_RUN", 20),
		// Finisher ships INERT (default false) — enabled deliberately after review.
		ReconcileFinisherEnabled:      getenvBool("RECONCILE_FINISHER_ENABLED", false),
		ReconcileFinisherGraceMinutes: getenvInt("RECONCILE_FINISHER_GRACE_MINUTES", 30),
		ReconcileValuesEnabled:        getenvBool("RECONCILE_VALUES_ENABLED", true),
		ReconcileValuesIntervalSec:    getenvInt("RECONCILE_VALUES_INTERVAL_SEC", 30),
		ReconcileEventsEnabled:        getenvBool("RECONCILE_EVENTS_ENABLED", true),
		ReconcileEventsIntervalSec:    getenvInt("RECONCILE_EVENTS_INTERVAL_SEC", 60),
		ReconcileEventsBatchSize:      getenvInt("RECONCILE_EVENTS_BATCH_SIZE", 200),

		ReconcileEventsCloseSweepEnabled:     getenvBool("RECONCILE_EVENTS_CLOSE_SWEEP_ENABLED", true),
		ReconcileEventsCloseSweepEveryNTicks: getenvInt("RECONCILE_EVENTS_CLOSE_SWEEP_EVERY_N_TICKS", 10),
		ReconcileEventsCloseSweepRecentHours: getenvInt("RECONCILE_EVENTS_CLOSE_SWEEP_RECENT_HOURS", 72),
		ReconcileEventsCloseSweepTimeoutSec:  getenvInt("RECONCILE_EVENTS_CLOSE_SWEEP_TIMEOUT_SEC", 30),
		ReconcileEventsCloseSweepBatchSize:   getenvInt("RECONCILE_EVENTS_CLOSE_SWEEP_BATCH_SIZE", 500),

		DLQRetryEnabled:                getenvBool("DLQ_RETRY_ENABLED", true),
		DLQRetryIntervalSec:            getenvInt("DLQ_RETRY_INTERVAL_SEC", 300),
		DLQRetryMaxAttempts:            getenvInt("DLQ_RETRY_MAX_ATTEMPTS", 5),
		DLQRetryBatchSize:              getenvInt("DLQ_RETRY_BATCH_SIZE", 50),
		DLQReanimateEnabled:            getenvBool("DLQ_REANIMATE_ENABLED", true),
		DLQReanimateIntervalSec:        getenvInt("DLQ_REANIMATE_INTERVAL_SEC", 600),
		DLQReanimateBatchSize:          getenvInt("DLQ_REANIMATE_BATCH_SIZE", 100),
		ComparatorEnabled:              getenvBool("COMPARATOR_ENABLED", true),
		ComparatorIntervalSec:          getenvInt("COMPARATOR_INTERVAL_SEC", 300),
		ComparatorOEEIntervalSec:       getenvInt("COMPARATOR_OEE_INTERVAL_SEC", 1800),
		ComparatorEventOpenStrandHours: getenvInt("COMPARATOR_EVENT_OPEN_STRAND_HOURS", 48),
		LogLevel:                       getenv("LOG_LEVEL", "info"),
	}
	// Sanity checks
	if cfg.ProdEnterpriseID <= 0 {
		return nil, fmt.Errorf("PROD_ENTERPRISE_ID required")
	}
	if cfg.StagingEnterpriseID <= 0 {
		return nil, fmt.Errorf("STAGING_ENTERPRISE_ID required")
	}
	// Guard the cadence divisor — a misconfigured 0 would panic the
	// events-sync tick on `closerTick % N`.
	if cfg.ReconcileEventsCloseSweepEveryNTicks < 1 {
		cfg.ReconcileEventsCloseSweepEveryNTicks = 1
	}
	return cfg, nil
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

func getenvBool(name string, fallback bool) bool {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	switch v {
	case "1", "true", "TRUE", "True", "yes":
		return true
	case "0", "false", "FALSE", "False", "no":
		return false
	}
	return fallback
}
