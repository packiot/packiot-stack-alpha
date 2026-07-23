// edge-transformer — per-factory Go service that consumes from a local
// RabbitMQ exchange (`plc.normalized.<tenant>`), runs deterministic Go
// transforms previously implemented as Node-RED subflows, and publishes
// transformed payloads onward.
//
// ADR-0009 Phase 2 SKELETON: this binary boots, connects to the broker,
// declares the per-tenant topology, runs N per-tenant consume goroutines
// (one Channel per tenant, shared Connection — the AMQP
// Channel-not-goroutine-safe discipline lifted from oeecloud-worker),
// dispatches every delivery to a SHADOW handler that logs+acks, and
// serves /healthz + /metrics on port 9102.
//
// What this skeleton deliberately does NOT do:
//
//   - No real transforms. Shadow handler is no-op (log+ack).
//   - No DB writes. No DB pool. (Phase 2 may add pgx if tenant discovery
//     moves off client.yaml onto packml_register; lift from oeecloud-worker
//     verbatim per ADR-0009 reuse rule.)
//   - No outbound publishes. The "transformed payload onward" leg lands
//     in Phase 3 alongside the outbox + reanimator topology.
//
// Reuse rule (ADR-0009 Errata Correction 2): every architectural element
// in this binary is lifted verbatim from services/oeecloud-worker or
// services/mirror-worker-go. If a future PR diverges from these patterns,
// the burden of proof is on that PR's author to justify why — not on the
// reviewer to spot the drift.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
	"golang.org/x/sync/errgroup"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/command"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/handlers"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/mqtt"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/outbox"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/secrets"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/shadowpub"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/tracing"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/transforms/calc_production_counters"
	"path/filepath"
	"strings"
)

// emittedByFlow counts envelopes enqueued to the outbox per destination
// flow (triple-emit). Package-level: the emit loop lives outside main.
var emittedByFlow = prometheus.NewCounterVec(prometheus.CounterOpts{
	Name: "edge_transformer_emitted_total",
	Help: "Envelopes enqueued to the outbox by destination flow (triple-emit).",
}, []string{"flow"})

func main() {
	// Docker healthcheck path. Distroless has no shell/curl/wget, so the
	// binary self-probes via HTTP. Exit 0 = healthy, non-zero = not.
	// Invoked via compose `healthcheck: ["CMD", "/usr/local/bin/edge-transformer", "--healthcheck"]`.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	logger := logp.Setup(cfg.LogLevel)

	logger.Info("edge-transformer starting",
		slog.String("mode", string(cfg.Mode)),
		slog.String("amqp_host", cfg.AMQPHost),
		slog.Int("amqp_port", cfg.AMQPPort),
		slog.String("source_exchange", cfg.SourceExchange),
		slog.String("worker_queue", cfg.WorkerQueue),
		slog.Int("prefetch", cfg.Prefetch),
		slog.Int("max_retries", cfg.MaxRetries),
		slog.Int("health_port", cfg.HealthPort),
		slog.String("client_yaml", cfg.ClientYAMLPath),
	)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Distributed tracing → Tempo. Opt-in: no-op unless OTEL_EXPORTER_OTLP_
	// ENDPOINT is set (see internal/tracing). The MQTT-receive span is the
	// data-plane trace root; its context is persisted through the outbox and
	// injected onto the AMQP publish so the whole PLC→worker→DB path is one
	// trace. A failure here never blocks boot.
	shutdownTracing, terr := tracing.Init(ctx, "edge-transformer")
	if terr != nil {
		logger.Warn("tracing init failed; continuing untraced", slog.String("err", terr.Error()))
	}
	defer func() { _ = shutdownTracing(context.Background()) }()

	// Load client.yaml. In the factory mode, missing/invalid client.yaml
	// is a hard boot failure — there's no tenant to route under, no
	// per-tenant queue to declare, nothing useful to do. Fail loud now
	// rather than spin in a zero-consumer state.
	//
	// TODO(ADR-0009 Phase 2): add a `dev_replay` branch that synthesizes
	// a fixture client.yaml when CLIENT_YAML_PATH points to a missing
	// path AND Mode==ModeDevReplay. Today both modes require a real
	// file on disk.
	clientCfg, err := clientconfig.Load(cfg.ClientYAMLPath)
	if err != nil {
		logger.Error("load client.yaml failed",
			slog.String("path", cfg.ClientYAMLPath),
			slog.String("err", err.Error()),
		)
		os.Exit(1)
	}
	tenants := clientCfg.Tenants()
	logger.Info("client config loaded",
		slog.String("customer", clientCfg.Customer),
		slog.String("environment", clientCfg.Environment),
		slog.Any("tenants", tenants),
		slog.Int("equipment_mappings", len(clientCfg.Equipments)),
	)

	// Fetch AMQP creds from AWS Secrets Manager. No DB creds in the
	// skeleton — the transformer doesn't touch Postgres yet.
	secretsCtx, secretsCancel := context.WithTimeout(ctx, 10*time.Second)
	defer secretsCancel()
	amqpCreds, err := secrets.FetchAMQPCreds(secretsCtx, cfg.AWSRegion, cfg.RabbitMQSecretID, cfg.AMQPHost, cfg.AMQPPort)
	if err != nil {
		logger.Error("fetch rabbitmq secret failed",
			slog.String("err", err.Error()),
			slog.String("secret_id", cfg.RabbitMQSecretID),
		)
		os.Exit(1)
	}
	logger.Info("secrets fetched", slog.String("amqp", amqpCreds.Redacted()))

	// Shadow handler — Phase 2 placeholder. Same factory pattern
	// oeecloud-worker uses for its writers: stats struct held by main,
	// passed to the handler factory AND to the metrics collector closure
	// so both read from the same source.
	shadowStats := &handlers.ShadowStats{}
	shadowHandler := handlers.ShadowWithStats(logger, shadowStats)

	dispatcher := handlers.NewDispatcher(logger)
	// Per-tenant registration — PR #56 lesson applied at scaffold time:
	// EVERY tenant gets an explicit entry in the handler map. Falling
	// through to the fallback (which is also Shadow today) would mask
	// the failure mode oeecloud-worker spent hours debugging in PR #56.
	for _, t := range tenants {
		dispatcher.Register(fmt.Sprintf("%s.%s", cfg.SourceExchange, t), shadowHandler)
	}

	consumer := amqp.NewConsumer(cfg, amqpCreds.URL(), dispatcher, tenants, logger)

	// Prometheus instrumentation. Registry + collectors live in the
	// metrics pkg; consumer + main provide read closures via the
	// SetMetrics / RegisterXCollector callback pattern so amqp/handlers
	// stay decoupled from prometheus.
	mx := metrics.New()
	mx.Registry.MustRegister(emittedByFlow)
	mx.RegisterConsumerCollector(func() metrics.ConsumerSnapshot {
		return metrics.ConsumerSnapshot{
			Delivered:         consumer.DeliveredCount(),
			Acked:             consumer.AckedCount(),
			NackedToRetry:     consumer.NackedToRetryCount(),
			PublishedToFailed: consumer.PublishedToFailedCount(),
		}
	})
	// Per-tenant shadow counter — single-tenant in factory mode, but
	// the map shape generalizes. The skeleton reports the same total
	// observed value under each tenant label because Shadow doesn't yet
	// per-tenant its internal counter (Phase 2 splits this when real
	// handlers replace Shadow).
	mx.RegisterShadowCollector(func() metrics.ShadowSnapshot {
		out := make(map[string]uint64, len(tenants))
		v := shadowStats.Observed.Load()
		for _, t := range tenants {
			out[t] = v
		}
		return metrics.ShadowSnapshot{Observed: out}
	})
	consumer.SetMetrics(
		func(rk, tenant, result string) {
			mx.Deliveries.WithLabelValues(rk, tenant, result).Inc()
		},
		func(rk, tenant string, secs float64) {
			mx.Duration.WithLabelValues(rk, tenant).Observe(secs)
		},
	)

	// Health server aggregates per-component /healthz JSON (ADR-0011 P0-4).
	// Every runtime component that satisfies health.ComponentSnapshotter is
	// registered — currently: consumer, plus subscriber + shadowpub when
	// MQTT_ENABLED. Each contributes its Degraded() reason to the response;
	// overall healthy = every component healthy. Response is 503 with
	// structured `degraded_components` when any component is degraded.
	// ADR-0011 rule 4: silent-degrade is a bug.
	//
	// Health server starts first — so /healthz answers 200 during the
	// consumer's initial connect attempt. Without this the Docker
	// healthcheck races the broker dial on a slow factory uplink and the
	// container churns. Same trick used in mirror-worker-go's bootSnapshot.
	multi := health.NewMulti()
	if cfg.AMQPSourceEnabled {
		multi.Add(consumer) // deliberately absent post-10.9: a disabled
		// source must not read as degraded
	}
	healthSrv := health.New(fmt.Sprintf(":%d", cfg.HealthPort), multi, mx.Registry, logger)
	healthSrv.Start()

	// ── ADR-0010 Phase 2 wiring ─────────────────────────────────────────────
	// The Sparkplug B MQTT subscriber is feature-flagged behind MQTT_ENABLED.
	// When on, it runs alongside the AMQP consumer under an errgroup — either
	// exiting will cancel the shared context and wind the other down.
	//
	// The subscriber's Handler decodes the Sparkplug binary, resolves aliases
	// via the per-publisher StateStore, and logs the resolved metric names.
	// Shadow-mode: no downstream RMQ publish yet — that's Phase 2 completion,
	// deferred to a follow-up PR alongside the AMQP publisher package.
	// ── ADR-0010 Phase 3: Calc Production Counters port (shadow mode) ─────
	// When USE_GO_PORT=true, every counter-topic Sparkplug metric flowing
	// through the MQTT handler ALSO gets evaluated by the Go port. State
	// is kept in a process-local memState singleton (safe for single-
	// instance factory deployments; multi-instance needs Redis).
	//
	// Shadow mode: Decisions get logged + counted, but do NOT change the
	// shadowpub output. This lets ops compare the Go port's behavior to
	// Node-RED's via metrics BEFORE the actual cutover (Phase 4).
	//
	// Prometheus counters exposed:
	//   calc_evaluations_total{tenant, kind, outcome}
	//   calc_state_mutations_total{tenant, mutation_kind}
	//   calc_errors_total{tenant, reason}
	var calcState calc_production_counters.State
	var calcEvals *prometheus.CounterVec
	var calcMutations *prometheus.CounterVec
	var calcErrors *prometheus.CounterVec
	var calcMetricsEmitted *prometheus.CounterVec
	var calcStateSeeds *prometheus.CounterVec
	if cfg.UseGoPort {
		calcState = calc_production_counters.NewMemState()
		calcEvals = prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "calc_evaluations_total",
			Help: "Calc Production Counters port evaluations (ADR-0010 Phase 3 shadow mode).",
		}, []string{"tenant", "kind", "outcome"})
		calcMutations = prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "calc_state_mutations_total",
			Help: "Calc Production Counters port state mutations (ADR-0010 Phase 3).",
		}, []string{"tenant", "mutation_kind"})
		calcErrors = prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "calc_errors_total",
			Help: "Calc Production Counters port evaluation errors (ADR-0010 Phase 3).",
		}, []string{"tenant", "reason"})
		calcMetricsEmitted = prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "calc_metrics_emitted_total",
			Help: "Calc port per-metric emissions (Decision.Metrics entries) — comparator diff target vs Node-RED emission rate.",
		}, []string{"tenant", "kind"})
		calcStateSeeds = prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "calc_state_seeds_total",
			Help: "Non-counter Sparkplug metrics that seeded Calc port State (MachSpeed, Parameter*).",
		}, []string{"tenant", "seed_kind"})
		mx.Registry.MustRegister(calcEvals, calcMutations, calcErrors, calcMetricsEmitted, calcStateSeeds)
		logger.Info("calc_production_counters port ENABLED (shadow mode)",
			slog.String("adr", "ADR-0010 Phase 3"),
		)
	} else {
		logger.Info("calc_production_counters port disabled (USE_GO_PORT=false)")
	}

	var sparkplugStore *sparkplug.StateStore
	var mqttSub *mqtt.Subscriber
	var shadowPub *shadowpub.Publisher
	var outboxStore *outbox.Store // hoisted so shutdown block can close it
	if cfg.MQTTEnabled {
		sparkplugStore = sparkplug.NewStateStore()

		// ADR-0011 P1: sparkplug sequence-gap counter, labelled per publisher.
		// The OnSeqGap callback below feeds this counter, so ops can graph
		// "which factory edges are losing messages" as a per-edge time series.
		gapCounter := mx.NewSparkplugGapsCounter()
		sparkplugStore.OnSeqGap(func(key sparkplug.PublisherKey, expected, got uint64) {
			gapCounter.WithLabelValues(key.GroupID, key.EdgeNodeID, key.DeviceID).Inc()
			logger.Warn("sparkplug: sequence gap",
				slog.String("publisher", key.String()),
				slog.Uint64("expected", expected),
				slog.Uint64("got", got),
			)
		})

		// Shadow publisher — publishes resolved metrics to edge.plc-normalized
		// with source.type="go" so ADR-0008-style comparator can diff against
		// Phase 2.5b's Node-RED publisher output (source.type="nodered") on
		// the same exchange.
		var shadowErr error
		// ADR-0010 Phase 3 shadow-mode DB comparison: publish to the same
		// `oee` exchange oeecloud-node-red uses, with routing key
		// `sparkplug.data.<tenant>`. The envelope's source_type="go" makes
		// oeecloud-worker dispatch writes into shadow_go_port.* schema.
		shadowPub, shadowErr = shadowpub.New(amqpCreds.URL(), "oee", logger)
		if shadowErr != nil {
			logger.Error("shadowpub: failed to open channel — MQTT disabled",
				slog.String("err", shadowErr.Error()))
			shadowPub = nil
		} else {
			// #91 emit-liveness: fail /healthz if emit stalls (dead channel /
			// failing reconnect) so orchestration recycles instead of a silent
			// 27h gap. 0 disables. See shadowpub.emitStalled for the anti-flap
			// (recent-attempt) gate.
			shadowPub.LivenessTimeout = time.Duration(cfg.EmitLivenessTimeoutSeconds) * time.Second
			logger.Info("shadowpub emit-liveness configured",
				slog.Int("timeout_seconds", cfg.EmitLivenessTimeoutSeconds))
			// ADR-0011 P3 chaos-test fix: proactively watch NotifyClose and
			// re-dial when RMQ goes down. Without this, the drain loop's
			// PublishBytes returns ErrConfirmTimeout (not a connection error)
			// and the reconnect never fires. Ships in ctx so it dies with
			// the main errgroup on shutdown.
			shadowPub.StartConnectionMonitor(ctx, logger)
		}

		mqttCfg := mqtt.DefaultConfig()
		mqttCfg.BrokerURL = cfg.MQTTBrokerURL
		mqttCfg.ClientID = cfg.MQTTClientID
		mqttCfg.Username = cfg.MQTTUsername
		mqttCfg.Password = cfg.MQTTPassword
		if cfg.MQTTStaleThresholdSeconds <= 0 {
			mqttCfg.StaleThreshold = -1 // idle checks disabled (no MQTT source expected)
		} else {
			mqttCfg.StaleThreshold = time.Duration(cfg.MQTTStaleThresholdSeconds) * time.Second
		}

		calcHooks := calcHooks{
			state:          calcState,
			evals:          calcEvals,
			mutations:      calcMutations,
			errors:         calcErrors,
			metricsEmitted: calcMetricsEmitted,
			stateSeeds:     calcStateSeeds,
			// ADR-0037 Silver rules — off unless the env flags are set.
			calcCfg: calc_production_counters.Config{
				MonotonicityGuard: cfg.CalcMonotonicityGuard,
				CounterRollover:   cfg.CalcCounterRollover,
			},
		}
		if cfg.CalcMonotonicityGuard || cfg.CalcCounterRollover {
			logger.Info("ADR-0037 Silver cleaning rules ENABLED in Calc port",
				slog.Bool("monotonicity_guard", cfg.CalcMonotonicityGuard),
				slog.Bool("counter_rollover", cfg.CalcCounterRollover))
		}

		// ADR-0011 P2 outbox — store-and-forward between decode + publish.
		// When enabled, decoded envelopes get persisted to SQLite BEFORE
		// publish; the drain goroutine below handles the RMQ publish + retry.
		// The handler skips the direct publish path — all output flows
		// through the outbox.
		if cfg.OutboxEnabled && shadowPub != nil {
			if err := os.MkdirAll(filepath.Dir(cfg.OutboxPath), 0o755); err != nil {
				logger.Error("outbox: mkdir failed — outbox disabled",
					slog.String("path", cfg.OutboxPath),
					slog.String("err", err.Error()))
			} else {
				var oerr error
				outboxStore, oerr = outbox.Open(outbox.Config{Path: cfg.OutboxPath, Capacity: cfg.OutboxCap})
				if oerr != nil {
					logger.Error("outbox: open failed — outbox disabled",
						slog.String("path", cfg.OutboxPath),
						slog.String("err", oerr.Error()))
					outboxStore = nil
				} else {
					logger.Info("outbox ENABLED (store-and-forward)",
						slog.String("path", cfg.OutboxPath),
						slog.Int("capacity", cfg.OutboxCap),
						slog.String("adr", "ADR-0011 P2"))
				}
			}
		} else if cfg.OutboxEnabled {
			logger.Warn("outbox: enabled but shadowpub failed to init — outbox disabled")
		}

		// ADR-0012 Phase 3 dual-emit: when SHADOW_EMIT_REFACTORED=true, for
		// each inbound MQTT event we enqueue TWO envelopes to the outbox —
		// one with source_type="go" (routes to shadow_go_port on packiot,
		// existing ADR-0010 validation preserved) and one with
		// source_type="refactored" (routes to packiot_shadow public, new
		// ADR-0012 refactor POC). Default false → single-emit unchanged.
		emitRefactored := os.Getenv("SHADOW_EMIT_REFACTORED") == "true"
		// 10.9 cutover: also emit source_type="" (production route → F1
		// public) so plc-sim is the SINGLE source feeding all flows —
		// the bake stays same-reality and the nodered legacy leg retires.
		emitProduction := os.Getenv("SHADOW_EMIT_PRODUCTION") == "true"
		// #276 Phase-4 cutover: when true, the F3 (source_type=refactored)
		// envelope is built from the Calc port's delta+cumulative counters
		// instead of the raw cumulative resolved metrics. Gated separately
		// from SHADOW_EMIT_REFACTORED so the F3 flow can be flipped to the
		// corrected shape while F2 stays raw as the tsp12 divergence control.
		// Requires USE_GO_PORT=true (Calc must be running) to have any effect.
		emitCutoverRefactored := os.Getenv("CALC_CUTOVER_REFACTORED") == "true"
		if emitRefactored {
			logger.Info("shadow dual-emit enabled: publishing source_type=go AND source_type=refactored envelopes")
		}
		if emitProduction {
			logger.Info("TRIPLE-emit enabled (10.9): source_type=\"\" (F1 production route) also published")
		}
		if emitCutoverRefactored {
			logger.Info("#276 CALC CUTOVER enabled for F3: source_type=refactored emits Calc delta+cumulative counters + non-counter pass-through (raw cumulative counters bypassed)",
				slog.Bool("use_go_port", cfg.UseGoPort))
		}
		mqttSub = mqtt.NewSubscriber(mqttCfg, sparkplugHandler(sparkplugStore, shadowPub, outboxStore, calcHooks, emitRefactored, emitProduction, emitCutoverRefactored, logger), logger)

		// ADR-0011 P1: wire the drop-metric callback so ingestion queue
		// overflow is Prometheus-visible.
		droppedCounter := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_mqtt_dropped_events_total",
			Help: "Individual drop events (for alerting on rate of drops, separate from cumulative counter in the subscriber snapshot).",
		}, []string{"reason"})
		mx.Registry.MustRegister(droppedCounter)
		mqttSub.SetDroppedMetric(func(reason string) {
			droppedCounter.WithLabelValues(reason).Inc()
		})

		// ADR-0011 P1: register subscriber-level snapshot collector.
		mx.RegisterMQTTSubscriberCollector(func() metrics.MQTTSubscriberSnapshot {
			snap := mqttSub.SnapshotJSON()
			return metrics.MQTTSubscriberSnapshot{
				Received:     snap.Received,
				Handled:      snap.Handled,
				HandleErrors: snap.HandleErrors,
				Reconnects:   snap.Reconnects,
				Dropped:      mqttSub.DroppedCount(),
				Connected:    snap.Connected,
			}
		})

		// ADR-0011 P0-4: register subscriber + publisher with the health
		// aggregator so /healthz surfaces their degraded state.
		multi.Add(mqttSub)
		if shadowPub != nil {
			multi.Add(shadowPub)

			// ADR-0011 P1: register shadow publisher's publisher-confirms
			// counters so ops can alert on nack/timeout rate.
			mx.RegisterShadowPublisherCollector(func() metrics.ShadowPublisherSnapshot {
				return metrics.ShadowPublisherSnapshot{
					Published:       shadowPub.PublishedCount(),
					Confirmed:       shadowPub.ConfirmedCount(),
					Nacked:          shadowPub.NackedCount(),
					ConfirmTimeouts: shadowPub.ConfirmTimeoutCount(),
					Failed:          shadowPub.FailedCount(),
					InFlight:        shadowPub.InFlightBacklog(),
				}
			})
		}
		if outboxStore != nil {
			// Wrap outbox as a ComponentSnapshotter so /healthz shows depth
			// + degraded state when it backs up.
			multi.Add(&outboxHealth{store: outboxStore})
			// Prom collector — depth + oldest_age exposed via callback.
			outboxDepthGauge := prometheus.NewGaugeFunc(
				prometheus.GaugeOpts{
					Name: "outbox_depth",
					Help: "Current number of rows in the outbox awaiting drain.",
				},
				func() float64 {
					n, err := outboxStore.Depth(context.Background())
					if err != nil {
						return -1
					}
					return float64(n)
				},
			)
			outboxOldestGauge := prometheus.NewGaugeFunc(
				prometheus.GaugeOpts{
					Name: "outbox_oldest_age_seconds",
					Help: "Age of the oldest row in the outbox, in seconds.",
				},
				func() float64 {
					age, err := outboxStore.OldestAge(context.Background())
					if err != nil {
						return -1
					}
					return age.Seconds()
				},
			)
			mx.Registry.MustRegister(outboxDepthGauge, outboxOldestGauge)
		}

		modeDesc := "shadow (log resolved metrics; no rmq publish)"
		if shadowPub != nil {
			modeDesc = "shadow (publish to edge.plc-normalized with source.type=go)"
		}
		logger.Info("mqtt subscriber wired",
			slog.String("broker", cfg.MQTTBrokerURL),
			slog.String("client_id", cfg.MQTTClientID),
			slog.String("mode", modeDesc),
		)
	} else {
		logger.Info("mqtt subscriber disabled (MQTT_ENABLED=false)")
	}

	// ── ADR-0019 C1 edge command channel (machine-write path) ────────────────
	// The RETURN path: operator command → broker → transformer → SparkPlug
	// DCMD → PLC. GATED behind EDGE_COMMANDS_ENABLED (default false), so this
	// ships INERT: the consumer self-gates in Run (blocks on ctx, no dial) and
	// no DCMD publisher is opened. Only when the flag flips do we open the MQTT
	// DCMD publisher + register the command metrics.
	cmdMetrics := command.Metrics{}
	var cmdDevice *command.MQTTDevicePublisher
	startCmd := false
	if cfg.CommandsEnabled {
		cmdReceived := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_commands_received_total",
			Help: "Operator commands consumed from edge.commands.<tenant> (ADR-0019 C1).",
		}, []string{"tenant", "verb"})
		cmdExecuted := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_commands_executed_total",
			Help: "Commands translated to a SparkPlug DCMD and published to the PLC (ADR-0019 C1).",
		}, []string{"tenant", "verb"})
		cmdRejected := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_commands_rejected_total",
			Help: "Commands refused (allow-list / params / mapping / malformed) — no DCMD emitted (ADR-0019 C1).",
		}, []string{"tenant", "verb", "reason"})
		cmdAcked := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_commands_acked_total",
			Help: "Acks published to edge.commands.<tenant>.ack, by status (ADR-0019 C1).",
		}, []string{"tenant", "verb", "status"})
		mx.Registry.MustRegister(cmdReceived, cmdExecuted, cmdRejected, cmdAcked)
		cmdMetrics = command.Metrics{
			Received: func(t, v string) { cmdReceived.WithLabelValues(t, v).Inc() },
			Executed: func(t, v string) { cmdExecuted.WithLabelValues(t, v).Inc() },
			Rejected: func(t, v, r string) { cmdRejected.WithLabelValues(t, v, r).Inc() },
			Acked:    func(t, v, s string) { cmdAcked.WithLabelValues(t, v, s).Inc() },
		}

		var derr error
		cmdDevice, derr = command.NewMQTTDevicePublisher(
			cfg.MQTTBrokerURL, cfg.MQTTClientID+"-cmd", cfg.MQTTUsername, cfg.MQTTPassword, logger)
		if derr != nil {
			logger.Error("command: DCMD publisher init failed — command channel NOT started",
				slog.String("err", derr.Error()))
		} else {
			startCmd = true
			logger.Info("edge command channel ENABLED",
				slog.Any("allowed_verbs", cfg.CommandsAllowed),
				slog.String("edge_node", cfg.CommandsEdgeNode))
		}
	} else {
		logger.Info("edge command channel disabled (EDGE_COMMANDS_ENABLED=false)")
	}
	cmdConsumer := command.NewConsumer(cfg, amqpCreds.URL(), tenants, cmdDevice, cmdMetrics, logger)
	multi.Add(cmdConsumer)

	// Run AMQP consumer + optional MQTT subscriber concurrently. First error
	// (or ctx cancellation) tears both down. errgroup guarantees Wait blocks
	// until every goroutine returns.
	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		if !cfg.AMQPSourceEnabled {
			// 10.9 cutover: MQTT is THE ingest; the nodered wrap's
			// exchange stays declared but unconsumed.
			logger.Info("AMQP source DISABLED (10.9 cutover — MQTT is the ingest)")
			<-gctx.Done()
			return nil
		}
		if err := consumer.Run(gctx); err != nil && !errors.Is(err, context.Canceled) {
			return fmt.Errorf("amqp consumer: %w", err)
		}
		return nil
	})
	if mqttSub != nil {
		g.Go(func() error {
			if err := mqttSub.Run(gctx); err != nil && !errors.Is(err, context.Canceled) {
				return fmt.Errorf("mqtt subscriber: %w", err)
			}
			return nil
		})
	}
	if outboxStore != nil && shadowPub != nil {
		g.Go(func() error {
			if err := runOutboxDrain(gctx, outboxStore, shadowPub, logger); err != nil && !errors.Is(err, context.Canceled) {
				return fmt.Errorf("outbox drain: %w", err)
			}
			return nil
		})
	}
	// Command consumer. When DISABLED it self-gates (Run blocks on ctx, no
	// dial). When ENABLED-but-publisher-init-failed we skip it entirely to
	// avoid publishing through a nil device. Otherwise it consumes.
	if !cfg.CommandsEnabled || startCmd {
		g.Go(func() error {
			if err := cmdConsumer.Run(gctx); err != nil && !errors.Is(err, context.Canceled) {
				return fmt.Errorf("command consumer: %w", err)
			}
			return nil
		})
	} else {
		logger.Warn("command channel enabled but publisher init failed — consumer not started")
	}
	if err := g.Wait(); err != nil {
		logger.Error("worker group exited with error", slog.String("err", err.Error()))
	}

	if shadowPub != nil {
		_ = shadowPub.Close()
	}
	if cmdDevice != nil {
		cmdDevice.Close()
	}
	if outboxStore != nil {
		_ = outboxStore.Close()
	}

	// Graceful shutdown for the health server (5s budget).
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	_ = healthSrv.Shutdown(shutdownCtx)

	logger.Info("edge-transformer stopped")
}

// calcHooks bundles the Calc Production Counters shadow-mode hooks. Passed
// to sparkplugHandler as a struct so the signature stays small even as
// we add more shadow-mode signals.
type calcHooks struct {
	state     calc_production_counters.State
	evals     *prometheus.CounterVec
	mutations *prometheus.CounterVec
	errors    *prometheus.CounterVec
	// metricsEmitted counts individual Metric entries the port would
	// emit — increments for every entry in Decision.Metrics. This lets
	// operators diff against Node-RED's actual emission rate at the same
	// tenant/kind granularity.
	metricsEmitted *prometheus.CounterVec
	// stateSeeds counts non-counter metrics recognized by seedFromMetric.
	stateSeeds *prometheus.CounterVec
	// calcCfg carries the ADR-0037 Silver cleaning-rule flags into every
	// Calc evaluation. Zero value = all rules off = byte-identical output.
	calcCfg calc_production_counters.Config
}

// enabled reports whether shadow-mode Calc is on. All hooks are nil when off.
func (h calcHooks) enabled() bool { return h.state != nil }

// isCounterMetricName returns the CounterKind if this Sparkplug metric name
// is a Calc-relevant counter, or CounterKindUnknown otherwise. Substring
// match on the JS convention.
func isCounterMetricName(name string) calc_production_counters.CounterKind {
	switch {
	case strings.Contains(name, "ProdProcessedCount"):
		return calc_production_counters.CounterKindProcessed
	case strings.Contains(name, "ProdConsumedCount"):
		return calc_production_counters.CounterKindConsumed
	case strings.Contains(name, "ProdDefectiveCount"):
		return calc_production_counters.CounterKindDefective
	default:
		return calc_production_counters.CounterKindUnknown
	}
}

// isLineLevelMetricName reports whether a metric name is a LINE-level
// (unit-less) topic rather than a per-machine (Unit) topic. It mirrors the
// canonical line-vs-unit rule used everywhere else in the stack — the
// oeecloud-worker resolver's Metric.IsLineTopic / TopicForRegister and the
// Node-RED "Prepare Incoming Message" node: when path segment index 4 is a
// PackML process keyword (Admin/Status/Command) there is no Unit segment, so
// the topic is a LINE. A Unit topic carries the unit name at index 4, pushing
// the process keyword to index 5. Case-insensitive to match the resolver
// (Sparkplug topic casing varies across PLCs).
//
//	CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount             → line (parts[4]="Admin")
//	CPACK/SC/LINHAS/L5/TEXA/Admin/ProdConsumedCount/65/Unit → unit (parts[4]="TEXA")
func isLineLevelMetricName(name string) bool {
	parts := strings.Split(name, "/")
	if len(parts) < 5 {
		return false
	}
	switch strings.ToLower(parts[4]) {
	case "admin", "status", "command":
		return true
	}
	return false
}

// seedFromMetric writes non-counter Sparkplug metrics into the Calc port's
// State singleton so subsequent counter evaluations have the parameter
// context they need (MachSpeed, Parameter*30761*, etc.). Silently no-ops
// on unknown metric names. Returns true if the metric was recognized.
func (h calcHooks) seedFromMetric(tenant string, metric sparkplug.ResolvedMetric) bool {
	// MachSpeed: nominal machine speed used by Phase 7 threshold + Phase 8
	// glitch guard (prodSpeed < 3*machspeed). Numeric; coerce to float64.
	if strings.HasSuffix(metric.Name, "/Status/MachSpeed") {
		var v float64
		switch x := metric.Value.(type) {
		case int64:
			v = float64(x)
		case uint64:
			v = float64(x)
		case int32:
			v = float64(x)
		case uint32:
			v = float64(x)
		case int:
			v = float64(x)
		case float64:
			v = x
		case float32:
			v = float64(x)
		default:
			return false
		}
		_ = h.state.SetFloat(metric.Name, v)
		h.stateSeeds.WithLabelValues(tenant, "machspeed").Inc()
		return true
	}
	// Parameter*30750* (threshold_quant): percentage; float
	if strings.HasSuffix(metric.Name, "/Status/Parameter*30750*") {
		v, ok := metricAsFloat(metric.Value)
		if !ok {
			return false
		}
		_ = h.state.SetFloat(metric.Name, v)
		h.stateSeeds.WithLabelValues(tenant, "threshold_quant").Inc()
		return true
	}
	// Parameter30758 (threshold_mode): int enum
	if strings.HasSuffix(metric.Name, "/Status/Parameter30758") {
		v, ok := metricAsInt(metric.Value)
		if !ok {
			return false
		}
		_ = h.state.SetInt(metric.Name, v)
		h.stateSeeds.WithLabelValues(tenant, "threshold_mode").Inc()
		return true
	}
	// Parameter*30761* (external-speed flag): bool
	if strings.HasSuffix(metric.Name, "/Status/Parameter*30761*") {
		if b, ok := metric.Value.(bool); ok {
			_ = h.state.SetBool(metric.Name, b)
			h.stateSeeds.WithLabelValues(tenant, "external_speed_flag").Inc()
			return true
		}
	}
	// Parameter*30710* (counter multiplier): int
	if strings.HasSuffix(metric.Name, "/Status/Parameter*30710*") {
		v, ok := metricAsInt(metric.Value)
		if !ok {
			return false
		}
		_ = h.state.SetInt(metric.Name, v)
		h.stateSeeds.WithLabelValues(tenant, "counter_multiplier").Inc()
		return true
	}
	// Parameter30700 (line-machines CSV): string CSV like "61,62,63".
	// Split and store as []string so Phase 9 line-aggregation can compare
	// against machine index for first/last.
	if strings.HasSuffix(metric.Name, "/Status/Parameter30700") {
		s, ok := metric.Value.(string)
		if !ok || s == "" {
			return false
		}
		parts := strings.Split(s, ",")
		// Trim any whitespace around each entry (defensive).
		for i, p := range parts {
			parts[i] = strings.TrimSpace(p)
		}
		_ = h.state.SetStrings(metric.Name, parts)
		h.stateSeeds.WithLabelValues(tenant, "line_machines_csv").Inc()
		return true
	}
	return false
}

// metricAsInt coerces a sparkplug ResolvedMetric.Value to int64, matching
// JS parseInt truncation for floats and false-return for non-numerics.
func metricAsInt(v any) (int64, bool) {
	switch x := v.(type) {
	case int64:
		return x, true
	case uint64:
		return int64(x), true
	case int32:
		return int64(x), true
	case uint32:
		return int64(x), true
	case int:
		return int64(x), true
	case float64:
		return int64(x), true
	case float32:
		return int64(x), true
	}
	return 0, false
}

// extractMetricValue pulls the concrete typed value out of a wire-format
// sparkplug.Metric's oneof Value field. Duplicates the sparkplug package's
// private extractValue since we can't import it — used to hand-craft a
// ResolvedMetric from an NBIRTH so seedFromMetric can process it.
func extractMetricValue(m *sparkplug.Metric) any {
	switch v := m.GetValue().(type) {
	case *sparkplug.Metric_IntValue:
		return v.IntValue
	case *sparkplug.Metric_LongValue:
		return v.LongValue
	case *sparkplug.Metric_FloatValue:
		return v.FloatValue
	case *sparkplug.Metric_DoubleValue:
		return v.DoubleValue
	case *sparkplug.Metric_BooleanValue:
		return v.BooleanValue
	case *sparkplug.Metric_StringValue:
		return v.StringValue
	default:
		return nil
	}
}

// metricAsFloat coerces a ResolvedMetric.Value to float64.
func metricAsFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case float32:
		return float64(x), true
	case int64:
		return float64(x), true
	case uint64:
		return float64(x), true
	case int32:
		return float64(x), true
	case uint32:
		return float64(x), true
	case int:
		return float64(x), true
	}
	return 0, false
}

// runCalcShadow evaluates one ResolvedMetric through the Calc port in
// shadow mode. State mutations are applied to the singleton state so
// subsequent ticks see the accumulated deltas. Decision output is
// counted; the actual downstream publish path is UNCHANGED.
//
// Errors are logged + counted but never propagated — shadow mode must
// not break the normal handler chain.
//
// Returns the metrics the Calc port emitted for this input (Decision.Metrics)
// so the caller can assemble the refactored-flow (F3) #276 cutover envelope
// from delta+cumulative counters instead of raw cumulative values. Returns nil
// when the metric only seeded state, wasn't a counter, was dropped, or errored
// — i.e. "nothing Calc would emit downstream". State mutations are still
// applied in all cases, so the observability (F2 shadow_go_port) path is
// unchanged regardless of whether the caller consumes the return value.
func (h calcHooks) runShadow(ctx context.Context, tenant string, metric sparkplug.ResolvedMetric, ts time.Time, logger *slog.Logger) []calc_production_counters.Metric {
	// First: try to seed non-counter state (MachSpeed, parameters).
	// Recognized ones update State + increment stateSeeds; unknown ones
	// fall through and the caller ignores non-counter metrics.
	if h.seedFromMetric(tenant, metric) {
		return nil
	}
	kind := isCounterMetricName(metric.Name)
	if kind == calc_production_counters.CounterKindUnknown {
		return nil
	}
	// Build a Calc.Message. For shadow-mode observability we assume every
	// ResolvedMetric that matches a counter topic IS a trigger event —
	// the actual ***TRIG tagging happens upstream in Node-RED today. This
	// is a simplification that will change in Phase 4 Step 4.3 when the
	// AMQP-consumer shim adds proper tag detection.
	//
	// Value coercion: sparkplug.ResolvedMetric.Value is any; the JS coerces
	// via parseInt (truncating for floats, NaN→0 for non-numeric). We match
	// that semantic by branching on the concrete type produced by the
	// sparkplug decoder.
	var payload int64
	switch v := metric.Value.(type) {
	case int64:
		payload = v
	case uint64:
		payload = int64(v)
	case int32:
		payload = int64(v)
	case uint32:
		payload = int64(v)
	case int:
		payload = int64(v)
	case float64:
		payload = int64(v) // JS parseInt truncates
	case float32:
		payload = int64(v)
	case bool:
		// JS parseInt(true) = NaN → 0; but Sparkplug booleans as counter
		// values are almost certainly a config error worth flagging.
		h.errors.WithLabelValues(tenant, "bool_as_counter").Inc()
		return nil
	default:
		// Non-numeric — skip, count as error for observability.
		h.errors.WithLabelValues(tenant, "non_numeric_value").Inc()
		return nil
	}
	msg := calc_production_counters.Message{
		Topic:      metric.Name + "***TRIG",
		Payload:    payload,
		Timestamp:  ts,
		Tenant:     tenant,
		CmdTrigger: true,
	}
	dec, err := calc_production_counters.CalcWithConfig(msg, h.state, h.calcCfg)
	if err != nil {
		h.errors.WithLabelValues(tenant, "calc_error").Inc()
		logger.Warn("calc_production_counters: evaluation error",
			slog.String("tenant", tenant),
			slog.String("metric", metric.Name),
			slog.String("err", err.Error()),
		)
		return nil
	}
	outcome := "send"
	if !dec.SendDownstream {
		outcome = "drop"
	}
	h.evals.WithLabelValues(tenant, kind.String(), outcome).Inc()
	// Apply state mutations so subsequent ticks see updated counters.
	for _, m := range dec.StateUpdates {
		if err := m.Apply(h.state); err != nil {
			h.errors.WithLabelValues(tenant, "mutation_apply").Inc()
			continue
		}
		h.mutations.WithLabelValues(tenant, m.Kind).Inc()
	}
	// Count the per-metric emissions from Decision.Metrics. This is the
	// granularity ops need for comparator-style diffs against Node-RED.
	for _, em := range dec.Metrics {
		emKind := "unknown"
		switch {
		case strings.Contains(em.Name, "ProdProcessedCount"):
			emKind = "ProdProcessedCount"
		case strings.Contains(em.Name, "ProdConsumedCount"):
			emKind = "ProdConsumedCount"
		case strings.Contains(em.Name, "ProdDefectiveCount"):
			emKind = "ProdDefectiveCount"
		case strings.Contains(em.Name, "Status/StateCurrent"):
			emKind = "StateCurrent"
		}
		h.metricsEmitted.WithLabelValues(tenant, emKind).Inc()
	}
	logger.Debug("calc_production_counters: shadow decision",
		slog.String("tenant", tenant),
		slog.String("metric", metric.Name),
		slog.String("kind", kind.String()),
		slog.String("outcome", outcome),
		slog.Int("emitted_metrics", len(dec.Metrics)),
		slog.Int("state_mutations", len(dec.StateUpdates)),
	)
	_ = ctx // reserved for future context-aware state backends (Redis)
	// Return the emitted metrics so the caller can build the F3 cutover
	// envelope. Empty when Calc chose to drop (SendDownstream=false).
	return dec.Metrics
}

// buildCutoverMetrics assembles the F3 (#276 cutover) envelope's metric list:
// the Calc port's emitted counters (Value=delta / Counter=cumulative — the
// prod gross_production_incr/gross_production_val shape) followed by every
// NON-counter resolved metric passed through verbatim (MachSpeed, UnitMode,
// Parameter*, …), which Calc reads as state but never re-emits. The raw
// cumulative counter metrics are dropped — the Calc deltas replace them; that
// replacement IS the #276 fix (cagg was SUMming cumulatives into billions).
func buildCutoverMetrics(calcMetrics []calc_production_counters.Metric, resolved []sparkplug.ResolvedMetric) []shadowpub.Metric {
	out := make([]shadowpub.Metric, 0, len(calcMetrics)+len(resolved))
	for _, em := range calcMetrics {
		// #276 / ADR-0037(A): suppress ONLY Phase-9 member→line AGGREGATION
		// counters — NOT the line's own-stream Phase-8 counter. A Phase-9 line
		// emission double-counts against the pre-existing downstream line
		// derivation (the #456 two-writer bug: id 47 = 43629 Calc + 65453
		// downstream = 109082 → oee 1.425). But suppressing by line-level NAME
		// (the old rule) also dropped the line's OWN differenced counter, so a
		// tp=3 line whose PLC feeds its own bare-topic totalizer (CPACK #16
		// own-stream lines) got NOTHING from Calc — its raw cumulative
		// totalizer flowed to net_production_incr with net_production_val NULL
		// and the cagg SUMmed cumulatives into ~14,000× inflation (oee ≫ 1,
		// net > gross). Origin-tagging (LineAggregated) tells the two apart:
		// the own-stream Phase-8 counter (Value=delta, Counter=cumulative)
		// passes through and is differenced like a tp=1 machine; only the
		// double-counting Phase-9 aggregate is dropped. Machine (Unit) counters
		// and Phase-10 status were never line-level, so they are unaffected.
		if em.LineAggregated {
			continue
		}
		counter := float64(em.Counter)
		m := shadowpub.Metric{
			Name:      em.Name,
			Timestamp: em.Timestamp,
			Value:     em.Value,
			Counter:   &counter,
		}
		// curspeed rides only on the counter metric that carried it in the JS
		// (Consumed, or Processed under STATESPEED_THIS); zero → absent.
		if em.CurSpeed != 0 {
			cs := em.CurSpeed
			m.CurSpeed = &cs
		}
		out = append(out, m)
	}
	for _, m := range resolved {
		// Skip raw counters — the Calc deltas above are their replacement.
		if isCounterMetricName(m.Name) != calc_production_counters.CounterKindUnknown {
			continue
		}
		out = append(out, shadowpub.Metric{
			Name:      m.Name,
			Timestamp: int64(m.Timestamp),
			Value:     m.Value,
		})
	}
	return out
}

// sparkplugHandler is the MQTT subscriber's Handler for ADR-0010 Phase 2
// shadow mode. Decodes → resolves via the alias table → logs the resolved
// metric names + values. In the follow-up PR that adds the shadow AMQP
// publisher, this handler additionally publishes a normalized envelope to
// edge.plc-normalized.<tenant> for ADR-0008-style comparator validation
// against Node-RED's Phase 2.5b publisher.
//
// ADR-0010 Phase 3 add-on: when calcHooks.enabled(), each ResolvedMetric
// also runs through the Calc Production Counters Go port for shadow-mode
// observability. State mutations are applied to the singleton state so
// subsequent ticks see accumulated deltas; the shadowpub path is unchanged.
// outboxHealth wraps outbox.Store as a health.ComponentSnapshotter so
// /healthz shows depth + degraded state (backpressure).
type outboxHealth struct {
	store *outbox.Store
}

const (
	outboxDepthDegradedThreshold = 5000
	outboxOldestAgeDegraded      = 60 * time.Second
)

func (h *outboxHealth) Component() string { return "outbox" }

func (h *outboxHealth) SnapshotDetail() any {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	depth, _ := h.store.Depth(ctx)
	age, _ := h.store.OldestAge(ctx)
	return map[string]any{
		"depth":                depth,
		"oldest_age_seconds":   age.Seconds(),
		"degraded_threshold":   outboxDepthDegradedThreshold,
		"oldest_age_threshold": outboxOldestAgeDegraded.Seconds(),
	}
}

func (h *outboxHealth) Degraded() string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	depth, err := h.store.Depth(ctx)
	if err != nil {
		return fmt.Sprintf("depth query failed: %v", err)
	}
	if depth > outboxDepthDegradedThreshold {
		return fmt.Sprintf("outbox depth %d > threshold %d (drain lagging)", depth, outboxDepthDegradedThreshold)
	}
	age, err := h.store.OldestAge(ctx)
	if err == nil && age > outboxOldestAgeDegraded {
		return fmt.Sprintf("oldest row %s (threshold %s) — drain stuck", age, outboxOldestAgeDegraded)
	}
	return ""
}

// outboxEnvelope is the shape written to outbox.Message.Payload. Carries
// enough info for the drain goroutine to publish without re-decoding the
// original Sparkplug binary.
type outboxEnvelope struct {
	RoutingKey string `json:"routing_key"`
	MessageID  string `json:"message_id"`
	Body       []byte `json:"body"` // pre-marshaled envelope JSON
	// Traceparent carries the W3C trace context of the MQTT-receive span
	// ACROSS the durable outbox boundary — an in-process span can't survive
	// the persist-then-drain gap, so we serialize it here and reconstruct the
	// parent at drain time. omitempty: old rows (and the untraced default)
	// simply start a fresh producer span. See runOutboxDrain.
	Traceparent string `json:"traceparent,omitempty"`
}

// runOutboxDrain is a long-running goroutine that peeks outbox rows,
// publishes each to RMQ via shadowpub.PublishBytes, and deletes on
// confirmed ACK. On failure it MarkAttempt's the row with exponential
// backoff so the next Peek skips it until the backoff window elapses.
//
// One drain goroutine per Store — the Store's internal mutex serializes
// its own operations, so this is safe. Sequential drain matches
// shadowpub's sequential confirm handling.
func runOutboxDrain(ctx context.Context, store *outbox.Store, publisher *shadowpub.Publisher, logger *slog.Logger) error {
	const (
		batchSize      = 10
		idleSleep      = 200 * time.Millisecond
		initialBackoff = 1 * time.Second
		maxBackoff     = 60 * time.Second
	)
	backoff := func(attempts int) time.Duration {
		d := initialBackoff
		for i := 0; i < attempts && d < maxBackoff; i++ {
			d *= 2
		}
		if d > maxBackoff {
			d = maxBackoff
		}
		return d
	}

	for {
		if err := ctx.Err(); err != nil {
			return nil
		}
		msgs, err := store.Peek(ctx, batchSize)
		if err != nil {
			if errors.Is(err, outbox.ErrOutboxEmpty) {
				// Empty outbox is the steady state — sleep + poll again.
				select {
				case <-ctx.Done():
					return nil
				case <-time.After(idleSleep):
				}
				continue
			}
			logger.Warn("outbox: Peek failed", slog.String("err", err.Error()))
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(idleSleep):
			}
			continue
		}
		if len(msgs) == 0 {
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(idleSleep):
			}
			continue
		}
		for _, m := range msgs {
			if err := ctx.Err(); err != nil {
				return nil
			}
			var env outboxEnvelope
			if err := json.Unmarshal(m.Payload, &env); err != nil {
				// Poisoned row — can't unmarshal, no point retrying.
				logger.Error("outbox: poisoned row (unmarshal) — deleting",
					slog.Int64("id", m.ID),
					slog.String("err", err.Error()))
				_ = store.Delete(ctx, m.ID)
				continue
			}
			// Reconstruct the receive-side trace context persisted in the
			// envelope, then open a producer span whose parent is that receive
			// span. The wall-clock gap between the two is the outbox dwell
			// time — visible in Tempo as the space between the spans.
			drainCtx := ctx
			if env.Traceparent != "" {
				drainCtx = otel.GetTextMapPropagator().Extract(ctx,
					propagation.MapCarrier{"traceparent": env.Traceparent})
			}
			drainCtx, span := otel.Tracer("edge-transformer").Start(drainCtx, "publish "+env.RoutingKey,
				trace.WithSpanKind(trace.SpanKindProducer))
			pubCtx, cancel := context.WithTimeout(drainCtx, 10*time.Second)
			err := publisher.PublishBytes(pubCtx, env.RoutingKey, env.MessageID, env.Body)
			cancel()
			if err != nil {
				span.RecordError(err)
			}
			span.End()
			if err != nil {
				bo := backoff(m.Attempts + 1)
				logger.Warn("outbox: publish failed — will retry",
					slog.Int64("id", m.ID),
					slog.Int("attempts", m.Attempts),
					slog.Duration("backoff", bo),
					slog.String("err", err.Error()))
				_ = store.MarkAttempt(ctx, m.ID, bo)
				continue
			}
			if err := store.Delete(ctx, m.ID); err != nil {
				logger.Warn("outbox: delete failed post-confirm",
					slog.Int64("id", m.ID),
					slog.String("err", err.Error()))
			}
		}
	}
}

func sparkplugHandler(store *sparkplug.StateStore, publisher *shadowpub.Publisher, outboxStore *outbox.Store, calc calcHooks, emitRefactored, emitProduction, cutoverRefactored bool, logger *slog.Logger) mqtt.Handler {
	return func(ctx context.Context, topic mqtt.Topic, body []byte) error {
		// Root of the data-plane trace. The MQTT hop upstream can't carry a
		// parent (paho v3.1.1 has no user-properties), so receive is the trace
		// origin. The span context is serialized into each outbox envelope
		// below so the drain-side publish continues this trace. No-op tracer
		// unless OTEL_EXPORTER_OTLP_ENDPOINT is set.
		ctx, span := otel.Tracer("edge-transformer").Start(ctx, "mqtt.receive "+topic.MessageType,
			trace.WithSpanKind(trace.SpanKindConsumer),
			trace.WithAttributes(
				attribute.String("messaging.system", "mqtt"),
				attribute.String("sparkplug.group_id", topic.GroupID),
				attribute.String("sparkplug.message_type", topic.MessageType),
			))
		defer span.End()

		payload, err := sparkplug.Decode(body)
		if err != nil {
			return fmt.Errorf("decode: %w", err)
		}
		key := sparkplug.PublisherKey{
			GroupID:    topic.GroupID,
			EdgeNodeID: topic.EdgeNodeID,
			DeviceID:   topic.DeviceID,
		}
		resolved, err := store.Ingest(key, topic.MessageType, payload)
		if err != nil {
			// ErrNoBirth for DATA before BIRTH — expected on cold start until
			// the next NBIRTH arrives. Log warn, don't error the handler.
			if errors.Is(err, sparkplug.ErrNoBirth) {
				logger.Warn("sparkplug: data before birth (waiting for NBIRTH)",
					slog.String("publisher", key.String()),
					slog.String("message_type", topic.MessageType),
				)
				return nil
			}
			return fmt.Errorf("ingest: %w", err)
		}
		if resolved == nil {
			// BIRTH/DEATH/CMD — state updated, no downstream output.
			// EXCEPTION for Phase 3 shadow: seed non-counter parameters from
			// NBIRTH so subsequent NDATA has the parameter context (MachSpeed,
			// Parameter*) it needs. Without this, Phase 8's glitch guard
			// (prodSpeed < 3*machspeed) suppresses every emission because
			// machspeed defaults to 0.
			if calc.enabled() && topic.MessageType == "NBIRTH" {
				for _, m := range payload.GetMetrics() {
					name := m.GetName()
					if name == "" {
						continue // skip metrics that only have alias (never in NBIRTH)
					}
					rm := sparkplug.ResolvedMetric{
						Name:  name,
						Alias: m.GetAlias(),
						Value: extractMetricValue(m),
					}
					_ = calc.seedFromMetric(topic.GroupID, rm)
				}
			}
			logger.Debug("sparkplug: state updated",
				slog.String("publisher", key.String()),
				slog.String("message_type", topic.MessageType),
				slog.Int("metrics", len(payload.GetMetrics())),
			)
			return nil
		}
		// ADR-0010 Phase 3 shadow-mode: run Calc port for every counter-topic
		// metric BEFORE the shadowpub publish. Non-mutating with respect to
		// the outgoing message — updates only the Calc State singleton +
		// Prometheus counters.
		//
		// #276 cutover: collect the metrics Calc emits so the F3
		// ("refactored") envelope below can be built from delta+cumulative
		// counters instead of the raw cumulative values that blow up the cagg.
		var calcMetrics []calc_production_counters.Metric
		if calc.enabled() {
			for _, m := range resolved.Metrics {
				// Use the metric's SOURCE timestamp (PLC sample time), not
				// ingest time. This is what prod Node-RED feeds Calc
				// (msg.timestamp) and it keeps the cutover-F3 ts_value aligned
				// with the raw-F3 path, so the tsp12 replay comparator diffs
				// apples-to-apples. Zero → Calc falls back to now().
				var ts time.Time
				if src := m.Timestamp; src > 0 {
					ts = time.UnixMilli(int64(src))
				}
				calcMetrics = append(calcMetrics, calc.runShadow(ctx, topic.GroupID, m, ts, logger)...)
			}
		}

		// DATA — publish per-metric envelopes to edge.plc-normalized.<tenant>
		// for ADR-0008 comparator validation. Two paths:
		//
		//   1. Outbox path (ADR-0011 P2, when outboxStore != nil): build
		//      envelope + marshal + Enqueue. Drain goroutine handles the
		//      actual RMQ publish + retry-on-nack. Crash-consistent.
		//   2. Direct path (default): publisher.Publish inline with
		//      confirms + typed errors. Fastest but loses in-flight on
		//      crash between decode and confirm.
		if outboxStore != nil {
			// Outbox path: one envelope-per-payload marshaled + persisted.
			// The new envelope shape is a single-message-many-metrics
			// oeecloud-compatible payload (see shadowpub.BuildEnvelope).
			// Routing key `sparkplug.data.<tenant>` on the `oee` exchange
			// so oeecloud-worker's per-tenant queue picks it up.
			//
			// Source types emitted (ADR-0012 Phase 3):
			//   - "go"         → shadow_go_port.* on packiot DB (default,
			//                    ADR-0010 comparison, always emitted)
			//   - "refactored" → public.* on packiot_shadow DB (opt-in via
			//                    SHADOW_EMIT_REFACTORED=true env)
			tenant := strings.ToLower(topic.GroupID)
			// 10.9 POST-CUTOVER FIX: the worker consumes the EXACT key
			// "sparkplug.data" (per-tenant queues retired with legacy
			// ingest). The tenant-suffixed key published the entire
			// post-cutover stream into an unconsumed queue — 17k
			// messages, found because a NEW dashboard metric stayed
			// empty while every row-count check passed (the fan-out
			// was feeding the tables). Tenant rides inside the envelope.
			routingKey := "sparkplug.data"

			sourceTypes := []string{"go"}
			if emitRefactored {
				sourceTypes = append(sourceTypes, "refactored")
			}
			if emitProduction {
				sourceTypes = append(sourceTypes, "") // F1 production route
			}
			for _, st := range sourceTypes {
				flow := "f2_shadow_go_port"
				switch st {
				case "refactored":
					flow = "f3_packiot_shadow"
				case "":
					flow = "f1_public"
				}
				emittedByFlow.WithLabelValues(flow).Inc()

				// #276 cutover: when CALC_CUTOVER_REFACTORED is on, the F3
				// ("refactored") flow emits Calc-derived delta+cumulative
				// counters (Value=delta, Counter=cumulative — prod's
				// gross_production_incr/val shape) plus non-counter pass-through
				// metrics, instead of the raw cumulative counters that the cagg
				// SUMs into billions. Every other flow (go/F2, ""/F1) keeps the
				// raw resolved metrics — F2 stays raw-and-blown-up on PURPOSE,
				// as the validating divergence against tsp12. Default OFF = zero
				// behavior change until the flag is flipped for F3 only.
				var env shadowpub.Envelope
				if st == "refactored" && cutoverRefactored && calc.enabled() {
					env = shadowpub.BuildEnvelopeFromMetrics(
						"outbox", st, int64(resolved.Timestamp),
						buildCutoverMetrics(calcMetrics, resolved.Metrics),
					)
				} else {
					env = shadowpub.BuildEnvelope(shadowpub.EnvelopeInput{
						Tenant:          tenant,
						PublisherKey:    key.String(),
						Instance:        "outbox",
						Metrics:         resolved.Metrics,
						SourceTimestamp: int64(resolved.Timestamp),
						SourceType:      st,
					})
				}
				body, err := json.Marshal(env)
				if err != nil {
					logger.Warn("outbox: marshal envelope failed",
						slog.String("source_type", st),
						slog.String("err", err.Error()))
					continue
				}
				messageID := fmt.Sprintf("outbox-%s-%d", st, time.Now().UnixNano())
				// Serialize the receive span's trace context into the envelope
				// so the drain goroutine can reconstruct the parent after the
				// durable persist/drain gap. MapCarrier gives us the bare
				// traceparent string to store; empty when tracing is off.
				tpCarrier := propagation.MapCarrier{}
				otel.GetTextMapPropagator().Inject(ctx, tpCarrier)
				oxEnv := outboxEnvelope{
					RoutingKey:  routingKey,
					MessageID:   messageID,
					Body:        body,
					Traceparent: tpCarrier["traceparent"],
				}
				payload, err := json.Marshal(oxEnv)
				if err != nil {
					continue
				}
				if _, err := outboxStore.Enqueue(ctx, outbox.Message{
					Tenant:  tenant,
					Topic:   key.String(),
					Payload: payload,
				}); err != nil {
					logger.Warn("outbox: enqueue failed",
						slog.String("publisher", key.String()),
						slog.String("source_type", st),
						slog.String("err", err.Error()))
				}
			}
		} else if publisher != nil {
			// Direct-publish path (legacy — pre-outbox).
			if err := publisher.Publish(ctx, resolved); err != nil {
				switch {
				case errors.Is(err, shadowpub.ErrPublishNacked):
					// RabbitMQ actively refused — usually resource alarm
					// (memory or disk). Ops should check RMQ status.
					logger.Error("shadowpub: RabbitMQ NACKED message",
						slog.String("publisher", key.String()),
						slog.String("action", "check RabbitMQ resource alarms"),
						slog.String("err", err.Error()))
				case errors.Is(err, shadowpub.ErrConfirmTimeout):
					// Broker didn't answer in time — likely slow-write under
					// load or connection wobble. Broker may still commit;
					// message state is ambiguous.
					logger.Warn("shadowpub: RabbitMQ confirm timeout",
						slog.String("publisher", key.String()),
						slog.String("state", "ambiguous — RMQ may have committed"),
						slog.String("err", err.Error()))
				default:
					// Other errors (marshal, channel-closed, ctx.Cancel, etc.)
					logger.Warn("shadowpub: publish failed",
						slog.String("publisher", key.String()),
						slog.String("err", err.Error()))
				}
				// Don't fail the handler — keep alias table cursor advancing.
				// The failure IS observable via metrics + logs (ADR-0011).
				// ADR-0011 P2 will add a local outbox for the retry-and-persist
				// case; this MVP just surfaces the failure loud + moves on.
			}
		}
		logger.Info("sparkplug: data decoded",
			slog.String("publisher", key.String()),
			slog.Uint64("seq", resolved.Seq),
			slog.Int("metric_count", len(resolved.Metrics)),
			slog.String("first_metric", firstMetricName(resolved.Metrics)),
		)
		return nil
	}
}

func firstMetricName(metrics []sparkplug.ResolvedMetric) string {
	if len(metrics) == 0 {
		return ""
	}
	return metrics[0].Name
}

// runHealthcheck does an HTTP GET against the in-process /healthz endpoint
// and returns a process exit code: 0 if the body parses + healthy=true,
// 1 otherwise. Honors HEALTH_PORT just like the server side. Used by
// docker's HEALTHCHECK directive because distroless has no shell/wget.
//
// 2-second timeout — if /healthz takes longer than that to answer, the
// transformer is probably unhealthy anyway.
func runHealthcheck() int {
	port := 9102
	if p := os.Getenv("HEALTH_PORT"); p != "" {
		fmt.Sscanf(p, "%d", &port)
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/healthz", port)
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
