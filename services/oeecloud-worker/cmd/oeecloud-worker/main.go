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
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/events"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/handlers"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/pocontrol"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/reports"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/secrets"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/shiftresolver"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/tenants"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/writers"
)

func main() {
	// Docker healthcheck path. Distroless has no shell/curl/wget, so the
	// binary self-probes via HTTP. Exit 0 = healthy, non-zero = not.
	// Invoked via compose `healthcheck: ["CMD", "/usr/local/bin/oeecloud-worker", "--healthcheck"]`.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	logger := logp.Setup(cfg.LogLevel)

	logger.Info("oeecloud-worker starting",
		slog.String("amqp_host", cfg.AMQPHost),
		slog.String("worker_queue", cfg.WorkerQueue),
		slog.Int("prefetch", cfg.Prefetch),
		slog.Int("max_retries", cfg.MaxRetries),
		slog.Int("health_port", cfg.HealthPort),
	)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

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

	// Postgres pool — used by writers. Sized small (see db.New) because
	// the consume loop is single-goroutine; at most one query is in flight
	// at any time.
	pool, err := db.New(ctx, dbCreds, logger)
	if err != nil {
		logger.Error("postgres pool init failed", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer pool.Close()

	// ADR-0012 shadow DB (schema-refactor live POC). Only initialized
	// when POSTGRES_SHADOW_DB_NAME is set — production deploys leave it
	// unset and the handler routes source_type="refactored" back to the
	// main pool (with a warn log). This keeps the code path additive:
	// no live behavior change unless you opt-in via env.
	var shadowPool *pgxpool.Pool
	if cfg.PGShadowDBName != "" {
		shadowPool, err = db.NewForDatabase(ctx, dbCreds, cfg.PGShadowDBName, "oeecloud-worker-shadow", logger)
		if err != nil {
			logger.Error("shadow postgres pool init failed",
				slog.String("err", err.Error()),
				slog.String("shadow_db", cfg.PGShadowDBName))
			os.Exit(1)
		}
		defer shadowPool.Close()
		logger.Info("shadow pool ready — source_type=refactored envelopes route here",
			slog.String("shadow_db", cfg.PGShadowDBName))
	}

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
	discoverCancel()
	if err != nil {
		logger.Error("tenant discovery failed", slog.String("err", err.Error()))
		os.Exit(1)
	}
	logger.Info("tenants discovered from packml_register",
		slog.Int("count", len(activeTenants)),
		slog.Any("tenants", activeTenants))

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
		logger.Info("shift resolver enabled (ADR-0014 Phase 2) — shadow paths get Go-computed shifts")
	}

	mx := metrics.New()
	// One observer for every scheduled job → jobs_ticks_total{job,outcome}.
	jobObs := func(job, outcome string) { mx.JobTicks.WithLabelValues(job, outcome).Inc() }

	// ADR-0012 Wave 2 port #1 — customer_reports.speed writer (cust 33).
	if cfg.Speed33ReportEnabled {
		go reports.LoopSpeed33(ctx, pool, time.Duration(cfg.Speed33IntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0012 Wave 2 port #2 — customer_reports.shift writer (cust 6).
	if cfg.Shift06ReportEnabled {
		go reports.LoopShift06(ctx, pool, time.Duration(cfg.Shift06IntervalMinutes)*time.Minute, logger, jobObs)
	}

	// ADR-0014 P3a — events deriver for the shadow flows. Deployed
	// DISABLED; enabled at the Jul-9 close-out (one bake at a time).
	if cfg.EventsDeriverEnabled {
		dests := []events.Dest{{Name: "shadow_go_port", Pool: pool, EvSchema: "shadow_go_port", RefSchema: "public"}}
		if shadowPool != nil {
			dests = append(dests, events.Dest{Name: "packiot_shadow", Pool: shadowPool, EvSchema: "public", RefSchema: "public"})
		}
		go events.Loop(ctx, dests, config.CSVInts(cfg.EventsExcludedAreas), config.CSVInts(cfg.EventsExcludedEnterprises),
			time.Duration(cfg.EventsDeriverIntervalMin)*time.Minute, logger, jobObs)
	}

	// Sparkplug handler — top-level for routing-key "sparkplug.data".
	// Parses the AMQP payload, builds one Query per metric via the right
	// writer, and sends them as a single pgx.Batch.
	sparkplugHandler := handlers.NewSparkplugHandler(
		pool, shadowPool, equipmentValuesWriter, unsMetricsWriter, poParameterWriter, logger,
	)

	if cfg.POControlEnabled {
		sparkplugHandler.SetPOControl(pocontrol.NewHandler(resolver, logger))
		logger.Info("po-control lifecycle handler ENABLED (ADR-0010 10.3 slice 1)")
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
	// Surface PO Parameter skipped-id counters on /health so #32 (port
	// 30700 / 30800-30899) can be measured-then-decided instead of guessed.
	consumer.SetWriterStats(func() any {
		return map[string]any{"po_parameter": poParameterWriter.Stats()}
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

	logger.Info("oeecloud-worker stopped")
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
