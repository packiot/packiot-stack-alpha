// oeecloud-worker — Go worker replacing oeecloud-node-red for AMQP→Postgres
// stream ingestion. Designed to run in parallel with the existing Node-RED
// instance during migration: binds a separate queue (`oeecloud-worker-q`)
// to the same `oee` topic exchange, so both consumers see every published
// message without competing.
//
// This session: scaffold only — placeholder LogOnly handler. Future sessions
// add real handlers one at a time, migrating writes off Node-RED.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/bake"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/events"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/handlers"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/pocontrol"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/refsync"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/reports"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/rollup"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/secrets"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/shiftresolver"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/tenants"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/tracing"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/uns"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/writers"
)

func main() {
	// Docker healthcheck path. Distroless has no shell/curl/wget, so the
	// binary self-probes via HTTP. Exit 0 = healthy, non-zero = not.
	// Invoked via compose `healthcheck: ["CMD", "/usr/local/bin/oeecloud-worker", "--healthcheck"]`.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	// F2/F3 identity + int-overflow SENTINEL path (Task #21). A one-shot,
	// SELECT-only deploy gate: connect both DB planes, run internal/bake's
	// RunSentinel, print a PASS/FAIL report, exit non-zero on any determinism
	// regression or overflow. Invoked in CI via
	//   docker exec oeecloud-worker /usr/local/bin/oeecloud-worker --identity-sentinel
	// so it reuses the SAME creds path, pool config and schema routing as the
	// running worker. Never starts the AMQP consumer.
	if len(os.Args) > 1 && os.Args[1] == "--identity-sentinel" {
		os.Exit(runIdentitySentinel())
	}

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	logger := logp.Setup(cfg.LogLevel)

	logger.Info("stream-engine starting",
		slog.String("amqp_host", cfg.AMQPHost),
		slog.String("worker_queue", cfg.WorkerQueue),
		slog.Int("prefetch", cfg.Prefetch),
		slog.Int("max_retries", cfg.MaxRetries),
		slog.Int("health_port", cfg.HealthPort),
	)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Distributed tracing → Tempo. Opt-in: no-op unless OTEL_EXPORTER_OTLP_
	// ENDPOINT is set (see internal/tracing). The consumer extracts the
	// traceparent injected by the publisher, so a single message becomes one
	// trace spanning publish → consume → DB writes. A failure never blocks boot.
	shutdownTracing, terr := tracing.Init(ctx, "stream-engine")
	if terr != nil {
		logger.Warn("tracing init failed; continuing untraced", slog.String("err", terr.Error()))
	}
	defer func() { _ = shutdownTracing(context.Background()) }()

	// Fetch DB + AMQP creds from AWS Secrets Manager — CO-5 phase 2.
	// AMQP user is least-privilege (provisioned via rabbitmqctl), not
	// the broker admin. EC2 IAM role grants packiot/staging/* access.
	secretsCtx, secretsCancel := context.WithTimeout(ctx, 10*time.Second)
	defer secretsCancel()
	dbCreds, err := secrets.FetchDBCreds(secretsCtx, cfg.AWSRegion, cfg.PGSecretID)
	if err != nil {
		logger.Error("fetch db secret failed",
			slog.String("err", err.Error()),
			slog.String("secret_id", cfg.PGSecretID))
		os.Exit(1)
	}
	amqpCreds, err := secrets.FetchAMQPCreds(secretsCtx, cfg.AWSRegion, cfg.RabbitMQSecretID, cfg.AMQPHost, cfg.AMQPPort)
	if err != nil {
		logger.Error("fetch rabbitmq secret failed",
			slog.String("err", err.Error()),
			slog.String("secret_id", cfg.RabbitMQSecretID))
		os.Exit(1)
	}
	logger.Info("secrets fetched",
		slog.String("db", dbCreds.Redacted("oeecloud-worker")),
		slog.String("amqp", amqpCreds.Redacted()))

	// Postgres pool — shared by the ingest writer AND the concurrent
	// rollup/refresh jobs, so sized via config (see db.New / pool.go).
	pool, err := db.New(ctx, dbCreds, cfg.PGMaxConns, logger)
	if err != nil {
		logger.Error("postgres pool init failed", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer pool.Close()

	// ADR-0012 shadow DB (schema-refactor live POC). Only initialized
	// when POSTGRES_ANALYTICS_DB_NAME is set — production deploys leave it
	// unset and the handler routes source_type="refactored" back to the
	// main pool (with a warn log). This keeps the code path additive:
	// no live behavior change unless you opt-in via env.
	var analyticsPool *pgxpool.Pool
	if cfg.PGAnalyticsDBName != "" {
		analyticsPool, err = db.NewForDatabase(ctx, dbCreds, cfg.PGAnalyticsDBName, "oeecloud-worker-analytics", cfg.PGAnalyticsMaxConns, logger)
		if err != nil {
			logger.Error("shadow postgres pool init failed",
				slog.String("err", err.Error()),
				slog.String("analytics_db", cfg.PGAnalyticsDBName))
			os.Exit(1)
		}
		defer analyticsPool.Close()
		logger.Info("shadow pool ready — source_type=refactored envelopes route here",
			slog.String("analytics_db", cfg.PGAnalyticsDBName))

		// Ensure the shadow DB's TimescaleDB background-worker scheduler is
		// running. The launcher does NOT reliably auto-start it for
		// packiot_analytics (it skipped it — a scheduler was running for the stale
		// 61 MB `packiot_refactor` leftover but not the live 676 MB shadow DB),
		// leaving the 15 continuous-aggregate refresh policies DORMANT. That is
		// the true root of the F3 rollup timeouts: unrefreshed caggs sit days
		// behind, so every rollup query re-aggregates days of raw equipment_values
		// on the fly (a 6-day lag = a 53s realtime HashAggregate per query).
		// This call is idempotent and safe if the scheduler is already up, so
		// running it on every worker start self-heals the scheduler after any
		// DB restart. Best-effort: a failure here must not stop the worker.
		if _, err := analyticsPool.Exec(ctx, `SELECT _timescaledb_functions.start_background_workers()`); err != nil {
			logger.Warn("could not start shadow TimescaleDB background workers — cagg refresh may lag",
				slog.String("err", err.Error()))
		} else {
			logger.Info("ensured packiot_analytics TimescaleDB background workers are running (cagg refresh policies)")
		}
	}

	// Background-job destination list (rollups, events, uns, reports). Built
	// ONCE and shared — the slice is read-only. On staging the main-pool flow
	// is the F2 comparator (`shadow_go_port`); on a single-flow deployment set
	// SHADOW_GO_PORT_ENABLED=false so the jobs target `public` (the collapsed
	// F3-native flow) instead — otherwise every tick errors 42P01 on the absent
	// shadow_go_port schema and nothing writes to `public` (ADR-0045 G3).
	bgDests := flows.StandardFiltered(pool, analyticsPool, cfg.ShadowGoPortEnabled)
	logger.Info("background-job destinations resolved",
		slog.Bool("shadow_go_port_enabled", cfg.ShadowGoPortEnabled),
		slog.Int("dest_count", len(bgDests)))

	// Topic → equipment resolver. 5 min TTL on positive hits (packml_register
	// changes rarely — CS Admin re-onboards). 30 s negative TTL so unknown
	// topics don't hammer the DB on noisy publishers.
	resolver := sparkplug.NewResolver(pool, 5*time.Minute, 30*time.Second)

	// Tenant discovery — Strategy C Phase 1. Queries packml_register for
	// the lowercased set of active group_ids. The AMQP topology declares
	// per-tenant queues for each (legacy queue still receives all traffic
	// for now). New tenants require a worker restart in Phase 1; we'll
	// add dynamic discovery later if onboarding cadence demands it.
	discoverCtx, discoverCancel := context.WithTimeout(ctx, 10*time.Second)
	activeTenants, err := tenants.DiscoverActive(discoverCtx, pool)
	if !cfg.LegacyIngestEnabled {
		// 10.9 cutover: the transformer's triple-emit ("" route) feeds
		// F1 via the envelope queue; the nodered legacy leg retires.
		logger.Info("LEGACY INGEST DISABLED (10.9): per-tenant sparkplug.data queues not consumed")
		activeTenants = nil
		err = nil
	}
	discoverCancel()
	if err != nil {
		logger.Error("tenant discovery failed", slog.String("err", err.Error()))
		os.Exit(1)
	}
	logger.Info("tenants discovered from packml_register",
		slog.Int("count", len(activeTenants)),
		slog.Any("tenants", activeTenants))

	// Declarative environment scoping (WORKER_TENANT_ALLOWLIST). packml_register
	// lives on the SHARED main DB, and staging's prod→staging re-cuts drag in
	// foreign-tenant rows — without this filter the worker would declare a
	// queue-triple per tenant (~39 queues for 13 tenants) when staging owns only
	// cpack + sbxcpack. Empty allowlist = passthrough (the prod default, no
	// change). Composes with the LegacyIngest disable above: when legacy ingest
	// is off, activeTenants is already nil and there is nothing to filter, so we
	// only run the intersection when there ARE tenants in hand.
	if len(cfg.TenantAllowlist) > 0 && len(activeTenants) > 0 {
		discovered := activeTenants
		activeTenants = tenants.FilterAllowlist(discovered, cfg.TenantAllowlist)
		dropped := droppedTenants(discovered, activeTenants)
		logger.Info("tenant allowlist applied",
			slog.Any("allowlist", cfg.TenantAllowlist),
			slog.Any("discovered", discovered),
			slog.Any("allowed", activeTenants),
			slog.Any("dropped", dropped))
	}

	// Per-table writers. Writers no longer hold the pool — they Build()
	// *writers.Query objects that the handler collects into a pgx.Batch
	// and sends as ONE round-trip per AMQP delivery.
	equipmentValuesWriter := writers.NewEquipmentValues(resolver, logger)
	unsMetricsWriter := writers.NewUnsMetrics(resolver, logger)
	poParameterWriter := writers.NewPOParameter(resolver, logger)

	// ADR-0014 Phase 2 — Go port of piot_set_shift_on_equipment_values().
	// Fills shift columns on SHADOW-path writes only during the comparator
	// bake; Flow 1 keeps the trigger until 168h of zero divergence.
	if cfg.ShiftResolverEnabled {
		shiftRes := shiftresolver.New(pool, 5*time.Minute, logger)
		equipmentValuesWriter.SetShiftResolver(shiftRes)
		// ADR-0014 fold rollback flag: fold the shift columns into the
		// UPSERT (SHIFT_FILL_FOLDED=true) vs the legacy separate UPDATE
		// (default). DBA bake-safe 2026-07-13 — flip live, revert by flag.
		equipmentValuesWriter.SetShiftFillFolded(cfg.ShiftFillFolded)
		logger.Info("shift resolver enabled (ADR-0014 Phase 2) — Go-computed shifts",
			slog.Bool("shift_fill_folded", cfg.ShiftFillFolded))
	}

	// Increment sanity clamp (ADR-0037 Silver invariant, INCREMENT_SANITY_CLAMP_ENABLED).
	// Rejects physically-impossible production increments before the cagg SUM.
	// Default OFF → byte-identical writes. Set once at startup.
	equipmentValuesWriter.SetIncrementClamp(
		cfg.IncrementSanityClampEnabled,
		cfg.IncrementSanityClampK,
		cfg.IncrementSanityClampMinDtSec,
		cfg.IncrementSanityClampSpikeFloor,
	)
	if cfg.IncrementSanityClampEnabled {
		logger.Info("increment sanity clamp ENABLED (ADR-0037/ADR-0045 P1) — K·rated_speed·Δt bound + delta-from-zero spike floor",
			slog.Float64("k", cfg.IncrementSanityClampK),
			slog.Int("min_dt_seconds", cfg.IncrementSanityClampMinDtSec),
			slog.Float64("spike_floor", cfg.IncrementSanityClampSpikeFloor))
	}

	// ADR-0036 B1 medallion Bronze dual-write (BRONZE_RAW_APPEND). Default OFF →
	// no _raw INSERT is ever queued, so the writer is byte-identical. When on,
	// every merged equipment_values UPSERT (and event mint) is shadowed by an
	// append-only INSERT into the immutable equipment_values_raw/_events_raw.
	equipmentValuesWriter.SetBronzeRawAppend(cfg.BronzeRawAppend)
	if cfg.BronzeRawAppend {
		logger.Info("Bronze raw append ENABLED (ADR-0036 B1) — dual-write to *_raw immutable landing zone")
	}

	mx := metrics.New()
	// One observer for every scheduled job → jobs_ticks_total{job,outcome}.
	jobObs := func(job, outcome string) { mx.JobTicks.WithLabelValues(job, outcome).Inc() }

	// ADR-0012 Wave 2 port #1 — customer_reports.speed writer (cust 33).
	if cfg.Speed33ReportEnabled {
		go reports.LoopSpeed33(ctx, pool, cfg.Speed33CustomerID, time.Duration(cfg.Speed33IntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0012 Wave 2 port #2 — customer_reports.shift writer (cust 6).
	if cfg.Shift06ReportEnabled {
		go reports.LoopShift06(ctx, pool, cfg.Shift06CustomerID, time.Duration(cfg.Shift06IntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0012 Wave 2 port #3 — customer_reports.sap_data_sync writer
	// (cust 13). Ships disabled: cutover gated on #223 (back4-api must
	// target the pool key first).
	if cfg.Sap13ReportEnabled {
		go reports.LoopSap13(ctx, pool, cfg.Sap13CustomerID, cfg.Sap13ReasonsFromDim, time.Duration(cfg.Sap13IntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0014 P4 — enterprise-6 production data sync (main flow).
	if cfg.Sync06ReportEnabled {
		go reports.LoopSync06(ctx, pool, cfg.Sync06EnterpriseID, cfg.Sync06Target, time.Duration(cfg.Sync06IntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0014 P3b — po-runtime-recalc (the recalc_needed consumer;
	// closes the loop pocontrol opens).
	if cfg.PORecalcEnabled {
		go rollup.LoopRefresh(ctx, bgDests,
			cfg.PORecalcWindow, config.CSVInts(cfg.PORecalcExcludedEnterprises),
			time.Duration(cfg.PORecalcIntervalMinutes)*time.Minute, logger, jobObs,
			uns.RefreshCurrentJobs)
	}

	// ADR-0016 — side-by-side bake comparator (legacy F1 vs Go F2).
	if cfg.BakeComparatorEnabled {
		bake.Register(mx.Registry)
		go bake.Loop(ctx, pool, analyticsPool, 10*time.Minute, config.CSVInts(cfg.BakeEnterpriseIDs), logger, jobObs)
	}

	// ADR-0014 P3b — runtime-rollup (grain cascade: week+month).
	if cfg.RuntimeRollupEnabled {
		go rollup.LoopGrains(ctx, bgDests,
			config.CSVInts(cfg.EventsExcludedAreas), config.CSVInts(cfg.EventsExcludedEnterprises),
			config.CSVInts(cfg.RollupMachineLevelEnterprises), cfg.RollupShiftLimit,
			cfg.DQAlarmsEnabled, cfg.SilverClampEnabled,
			rollup.CountersAvail{
				Enabled:             cfg.CountersOnlyAvailEnabled,
				Equipments:          config.CSVInts(cfg.CountersOnlyAvailEquipments),
				IdleTimeoutSec:      cfg.CountersOnlyAvailIdleTimeoutSec,
				LineLeadEnabled:     cfg.CountersOnlyLineLeadEnabled,
				LineLeadEnterprises: config.CSVInts(cfg.CountersOnlyLineLeadEnterprises),
			},
			time.Minute, logger, jobObs)
	}
	// Drain recalc_needed hour rows the live rollup can't reach (stranded outside
	// its 65-min window). OFF by default — see RollupBackfillEnabled: needs query
	// work before it's safe to run against F2/F3.
	if cfg.RuntimeRollupEnabled && cfg.RollupBackfillEnabled {
		go rollup.LoopHourBackfill(ctx, bgDests,
			config.CSVInts(cfg.EventsExcludedAreas), config.CSVInts(cfg.EventsExcludedEnterprises),
			cfg.RollupBackfillLimit,
			time.Duration(cfg.RollupBackfillIntervalSeconds)*time.Second, logger, jobObs)
	}

	// F3 reference-plane sync — mirror master tables main→packiot_analytics so F3
	// rollups read the same reference plane as F2 (F2/F3 identity requirement).
	if analyticsPool != nil && cfg.RefSyncEnabled {
		go refsync.Loop(ctx, pool, analyticsPool,
			time.Duration(cfg.RefSyncIntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0014 P3b — runtime-provision (bucket matrix). Cadence configurable;
	// the 30-day horizon makes hourly re-walks wasteful (see LoopProvision).
	if cfg.RuntimeProvisionEnabled {
		provisionEvery := time.Duration(cfg.RuntimeProvisionIntervalHours) * time.Hour
		go rollup.LoopProvision(ctx, bgDests, provisionEvery, logger, jobObs)
	}

	// Provisional ideal-speed inference (counters-only tenants w/o nameplate).
	// Own loop, default OFF: fills equipments.production_speed from p95 observed
	// throughput for opted-in tp=3 lines so the rollup's ideal_speed COALESCE
	// chain can compute Performance. Disabled → no goroutine, zero statements,
	// byte-identical rollup. See internal/rollup/inferspeed.go.
	if cfg.ProvisionalSpeedEnabled {
		go rollup.LoopInferSpeed(ctx, bgDests,
			rollup.ProvisionalSpeed{
				Enabled:     cfg.ProvisionalSpeedEnabled,
				Equipments:  config.CSVInts(cfg.ProvisionalSpeedEquipments),
				WindowHours: cfg.ProvisionalSpeedWindowHours,
				MinMinutes:  cfg.ProvisionalSpeedMinMinutes,
				Percentile:  cfg.ProvisionalSpeedPercentile,
				Floor:       cfg.ProvisionalSpeedFloor,
			},
			logger, jobObs)
	}

	// ADR-0014 P3c — UNS provisioner + equipment week/month refreshers.
	if cfg.UnsRefreshEnabled {
		go uns.Loop(ctx, bgDests,
			config.CSVInts(cfg.EventsExcludedAreas), config.CSVInts(cfg.EventsExcludedEnterprises),
			time.Duration(cfg.UnsIntervalMinutes)*time.Minute, logger, jobObs)
	}

	// uns_equipment_current_metrics deriver — the frozen live-state
	// table's new mechanism (it lost its ingest writer at the 10.9
	// cutover; owner-approved in-engine derivation, 2026-07-07).
	// Its OWN job + cadence — flag-off until the flip. Freeze story +
	// per-column derivation ledger: internal/uns/current_metrics.go.
	if cfg.UnsCurrentMetricsEnabled {
		go uns.LoopCurrentMetrics(ctx, bgDests,
			time.Duration(cfg.UnsCurrentMetricsIntervalMinutes)*time.Minute, logger, jobObs)
	}

	// obd port — the box→production bridge (descriptor-driven).
	if cfg.BoxesBridgeEnabled {
		go reports.LoopBoxesBridge(ctx, bgDests, time.Minute, logger, jobObs)
	}

	// ADR-0014 — the label-adapter boxes pipeline (descriptor-driven).
	if cfg.Boxes13ReportEnabled {
		go reports.LoopBoxes(ctx, bgDests, time.Duration(cfg.Boxes13IntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0014 P3a — events deriver for the shadow flows. Deployed
	// DISABLED; enabled at the Jul-9 close-out (one bake at a time).
	if cfg.EventsDeriverEnabled {
		go events.Loop(ctx, bgDests, config.CSVInts(cfg.EventsExcludedAreas), config.CSVInts(cfg.EventsExcludedEnterprises),
			config.CSVInts(cfg.EventsWiderowStateEnterprises),
			time.Duration(cfg.EventsDeriverIntervalMin)*time.Minute, logger, jobObs)
	}

	// ADR-0010 §10.4 GAP-1 — CPAC (status_type=0) stop deriver. DARK,
	// DEFAULT OFF. Parallel path to the status_type=4 deriver above; writes a
	// separate shadow comparison table so flag-off is byte-identical. Do NOT
	// enable until the comparator (cpac_deriver_comparator.sql) gate passes.
	if cfg.CPACEventDerivationEnabled {
		go events.LoopCPAC(ctx, bgDests,
			events.CPACConfig{
				Enterprises:     config.CSVInts(cfg.CPACEventEnterprises),
				ThresholdDefSec: cfg.CPACStopThresholdDefaultSec,
				TargetTable:     cfg.CPACEventTargetTable,
			},
			time.Duration(cfg.CPACEventIntervalMin)*time.Minute, logger, jobObs)
	}

	// Sparkplug handler — top-level for routing-key "sparkplug.data".
	// Parses the AMQP payload, builds one Query per metric via the right
	// writer, and sends them as a single pgx.Batch.
	sparkplugHandler := handlers.NewSparkplugHandler(
		pool, analyticsPool, equipmentValuesWriter, unsMetricsWriter, poParameterWriter, logger,
	)
	sparkplugHandler.SetWriteMetric(mx.BatchWrites)
	sparkplugHandler.SetWriteMetric(mx.BatchWrites)
	sparkplugHandler.SetLegacyIngest(cfg.LegacyIngestEnabled)

	if cfg.POControlEnabled {
		pc := pocontrol.NewHandler(resolver, logger)
		sparkplugHandler.SetPOControl(pc)
		mx.RegisterPOControlCollector(func() metrics.POControlSnapshot {
			s := pc.Stats()
			return metrics.POControlSnapshot{Started: s.Started, Topology: s.Topology,
				Created: s.Created, Events: s.Events, Ended: s.Ended, NoOps: s.NoOps, Dropped: s.Dropped}
		})
		logger.Info("po-control lifecycle handler ENABLED (ADR-0010 10.3)")
	}

	dispatcher := handlers.NewDispatcher(logger)
	// Register the sparkplug handler for BOTH the legacy 2-segment key
	// (`sparkplug.data` — still emitted by any edge-nodered that hasn't
	// flipped to Strategy C Phase 2b yet) AND the per-tenant 3-segment
	// keys (`sparkplug.data.<tenant>`) that the per-tenant queues
	// declared in DeclareTopology actually deliver.
	//
	// Before this registration, only `sparkplug.data` was in the map.
	// On staging edge-nodered already publishes `sparkplug.data.cpack`,
	// so every delivery missed the map and fell through to the LogOnly
	// fallback — acks succeeded but NO write ever happened. The Strategy
	// C Phase 2a topology change moved per-tenant traffic onto the new
	// queues, but the dispatcher registration was left at the legacy
	// key. Symptom matched perfectly: /metrics counted ~17.5k acked on
	// `sparkplug.data.cpack` while `equipment_values` had 0 new rows.
	dispatcher.Register("sparkplug.data", sparkplugHandler.Handle)
	for _, t := range activeTenants {
		dispatcher.Register(fmt.Sprintf("sparkplug.data.%s", t), sparkplugHandler.Handle)
	}

	consumer := amqp.NewConsumer(cfg, amqpCreds.URL(), dispatcher, activeTenants, logger)

	// Strategy D — dynamic tenant discovery. Wire the periodic re-discovery
	// source + the handler to register for a newly-onboarded tenant's routing
	// key, so a client added to packml_register mid-run starts flowing within
	// TENANT_DISCOVERY_INTERVAL_SECONDS with NO worker restart (and no
	// disruption to the tenants already flowing). Gated on LegacyIngestEnabled
	// — the same condition under which per-tenant queues are consumed — so the
	// 10.9 legacy-disabled path stays byte-identical (discoverer left nil →
	// the discovery loop is inert).
	if cfg.LegacyIngestEnabled {
		consumer.SetTenantHandler(sparkplugHandler.Handle)
		consumer.SetDiscoverer(func(dctx context.Context) ([]string, error) {
			return tenants.DiscoverActive(dctx, pool)
		})
	}
	// Surface PO Parameter skipped-id counters on /health so #32 (port
	// 30700 / 30800-30899) can be measured-then-decided instead of guessed.
	consumer.SetWriterStats(func() any {
		return map[string]any{
			"po_parameter": poParameterWriter.Stats(),
			// Surface the sparkplug handler counters so the double-encode
			// poison-storm guard (task #92) is observable on /health — a
			// non-zero sparkplug_double_encoded_dropped means a producer is
			// double-marshaling envelopes onto the oee exchange.
			"sparkplug": sparkplugHandler.Stats(),
		}
	})

	// Prometheus instrumentation. Registry + collectors are wired in
	// the metrics pkg; consumer + main provide read closures via the
	// SetMetrics / RegisterXCollector callback pattern so amqp/writers
	// stay decoupled from prometheus.
	mx.RegisterConsumerCollector(func() metrics.ConsumerSnapshot {
		return metrics.ConsumerSnapshot{
			Delivered:         consumer.DeliveredCount(),
			Acked:             consumer.AckedCount(),
			NackedToRetry:     consumer.NackedToRetryCount(),
			PublishedToFailed: consumer.PublishedToFailedCount(),
		}
	})
	mx.RegisterPOParameterCollector(func() metrics.POParameterSnapshot {
		s := poParameterWriter.Stats()
		return metrics.POParameterSnapshot{
			WroteIdealSpeed:  s.WroteIdealSpeed,
			WroteAnalogs:     s.WroteAnalogs,
			SkippedLineOrder: s.SkippedLineOrder,
			SkippedPOCtl:     s.SkippedPOCtl,
			SkippedOther:     s.SkippedOther,
		}
	})
	consumer.SetMetrics(
		func(rk, result string) { mx.Deliveries.WithLabelValues(rk, result).Inc() },
		func(rk string, secs float64) { mx.Duration.WithLabelValues(rk).Observe(secs) },
	)

	// *amqp.Consumer.Snapshot() satisfies health.Snapshotter directly
	// since the redesigned interface uses concrete types.
	healthSrv := health.New(fmt.Sprintf(":%d", cfg.HealthPort), consumer, mx.Registry, logger)
	healthSrv.Start()

	// Consumer.Run blocks until ctx cancelled.
	if err := consumer.Run(ctx); err != nil && err != context.Canceled {
		logger.Error("consumer exited with error", slog.String("err", err.Error()))
	}

	// Graceful shutdown for the health server (5s budget).
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	_ = healthSrv.Shutdown(shutdownCtx)

	logger.Info("stream-engine stopped")
}

// droppedTenants returns the members of discovered that did NOT survive
// filtering — i.e. discovered minus kept. Log-only: it makes the allowlist's
// effect legible (which foreign tenants got scoped out) without changing any
// routing. O(n·m) is fine for the handful of tenants involved.
func droppedTenants(discovered, kept []string) []string {
	keptSet := make(map[string]struct{}, len(kept))
	for _, k := range kept {
		keptSet[k] = struct{}{}
	}
	var dropped []string
	for _, d := range discovered {
		if _, ok := keptSet[d]; !ok {
			dropped = append(dropped, d)
		}
	}
	return dropped
}

// runHealthcheck does an HTTP GET against the in-process /health endpoint
// and returns a process exit code: 0 if the body parses + healthy=true,
// 1 otherwise. Honors HEALTH_PORT just like the server side. Used by
// docker's HEALTHCHECK directive because distroless has no shell/wget.
//
// 2-second timeout — if /health takes longer than that to answer, the
// worker is probably unhealthy anyway.
func runHealthcheck() int {
	port := 9101
	if p := os.Getenv("HEALTH_PORT"); p != "" {
		fmt.Sscanf(p, "%d", &port)
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/health", port)
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: GET %s: %v\n", url, err)
		return 1
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: read body: %v\n", err)
		return 1
	}
	var meta struct {
		Healthy bool `json:"healthy"`
	}
	if err := json.Unmarshal(body, &meta); err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: parse body: %v\n", err)
		return 1
	}
	if !meta.Healthy {
		fmt.Fprintf(os.Stderr, "healthcheck: not healthy: %s\n", string(body))
		return 1
	}
	return 0
}

// runIdentitySentinel is the one-shot F2/F3 identity + int-overflow deploy gate
// (Task #21). SELECT-only. It connects the two DB planes exactly as the worker
// does (same creds path, same pool builders), runs internal/bake.RunSentinel
// over the configured enterprises, prints a compact PASS/FAIL report, and
// returns a process exit code:
//
//	0  — every surface PASS or SKIP, no overflow (gate green)
//	1  — a determinism regression, an overflow violation, OR the check itself
//	     could not run (fail-closed: a sentinel that cannot execute must never
//	     silently pass a deploy)
//
// SKIP (no data / one side entirely empty on a cold, unconverged stack) never
// fails the gate — the live bake gauge tracks sustained one-sidedness.
func runIdentitySentinel() int {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "identity-sentinel: config: %v\n", err)
		return 1
	}
	logger := logp.Setup(cfg.LogLevel)

	if cfg.PGAnalyticsDBName == "" {
		// No F3 plane configured → nothing to gate. Not a failure: on a plain
		// prod-shaped deploy without the shadow DB the sentinel is a no-op.
		logger.Warn("identity-sentinel: POSTGRES_ANALYTICS_DB_NAME unset — no F3 plane to check; skipping (exit 0)")
		return 0
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	dbCreds, err := secrets.FetchDBCreds(ctx, cfg.AWSRegion, cfg.PGSecretID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "identity-sentinel: fetch db creds: %v\n", err)
		return 1
	}
	// ADR-0032 Step 5: the F2 (shadow_go_port) plane is gone. Only the F3 plane
	// (public in packiot_analytics) is opened; the sentinel is now the per-plane
	// int-overflow gate on F3 (GATE 2 survived; the F2==F3 identity gates 1/3 did not).
	f3, err := db.NewForDatabase(ctx, dbCreds, cfg.PGAnalyticsDBName, "identity-sentinel-analytics", 2, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "identity-sentinel: F3 pool: %v\n", err)
		return 1
	}
	defer f3.Close()

	enterprises := config.CSVInts(cfg.BakeEnterpriseIDs)
	logger.Info("identity-sentinel running", slog.Any("enterprises", enterprises),
		slog.String("f3_db", cfg.PGAnalyticsDBName))

	rep, err := bake.RunSentinel(ctx, f3, enterprises)
	if err != nil {
		// Query-level failure: the gate could not evaluate. Fail closed — print
		// whatever partial report we have plus the error.
		fmt.Fprintf(os.Stderr, "identity-sentinel: check could not run (FAIL-CLOSED): %v\n", err)
		fmt.Println(rep.String())
		return 1
	}
	fmt.Println("F3 INT-OVERFLOW SENTINEL")
	fmt.Println(rep.String())
	if rep.Failed() {
		fmt.Fprintln(os.Stderr, "identity-sentinel: GATE FAILED — F3 int-overflow detected")
		return 1
	}
	return 0
}
