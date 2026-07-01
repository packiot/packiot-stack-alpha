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

	"golang.org/x/sync/errgroup"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/handlers"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/mqtt"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/secrets"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/shadowpub"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

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

	// Health server first — so /healthz answers 200 during the consumer's
	// initial connect attempt. Without this the Docker healthcheck races
	// the broker dial on a slow factory uplink and the container churns.
	// Same trick used in mirror-worker-go's bootSnapshot path.
	healthSrv := health.New(fmt.Sprintf(":%d", cfg.HealthPort), consumer, mx.Registry, logger)
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
	var sparkplugStore *sparkplug.StateStore
	var mqttSub *mqtt.Subscriber
	var shadowPub *shadowpub.Publisher
	if cfg.MQTTEnabled {
		sparkplugStore = sparkplug.NewStateStore()
		sparkplugStore.OnSeqGap(func(key sparkplug.PublisherKey, expected, got uint64) {
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
		shadowPub, shadowErr = shadowpub.New(amqpCreds.URL(), "edge.plc-normalized", logger)
		if shadowErr != nil {
			logger.Error("shadowpub: failed to open channel — MQTT disabled",
				slog.String("err", shadowErr.Error()))
			shadowPub = nil
		}

		mqttCfg := mqtt.DefaultConfig()
		mqttCfg.BrokerURL = cfg.MQTTBrokerURL
		mqttCfg.ClientID = cfg.MQTTClientID
		mqttCfg.Username = cfg.MQTTUsername
		mqttCfg.Password = cfg.MQTTPassword

		mqttSub = mqtt.NewSubscriber(mqttCfg, sparkplugHandler(sparkplugStore, shadowPub, logger), logger)
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

	// Run AMQP consumer + optional MQTT subscriber concurrently. First error
	// (or ctx cancellation) tears both down. errgroup guarantees Wait blocks
	// until every goroutine returns.
	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error {
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
	if err := g.Wait(); err != nil {
		logger.Error("worker group exited with error", slog.String("err", err.Error()))
	}

	if shadowPub != nil {
		_ = shadowPub.Close()
	}

	// Graceful shutdown for the health server (5s budget).
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	_ = healthSrv.Shutdown(shutdownCtx)

	logger.Info("edge-transformer stopped")
}

// sparkplugHandler is the MQTT subscriber's Handler for ADR-0010 Phase 2
// shadow mode. Decodes → resolves via the alias table → logs the resolved
// metric names + values. In the follow-up PR that adds the shadow AMQP
// publisher, this handler additionally publishes a normalized envelope to
// edge.plc-normalized.<tenant> for ADR-0008-style comparator validation
// against Node-RED's Phase 2.5b publisher.
func sparkplugHandler(store *sparkplug.StateStore, publisher *shadowpub.Publisher, logger *slog.Logger) mqtt.Handler {
	return func(ctx context.Context, topic mqtt.Topic, body []byte) error {
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
			// BIRTH/DEATH/CMD — state updated, no downstream output
			logger.Debug("sparkplug: state updated",
				slog.String("publisher", key.String()),
				slog.String("message_type", topic.MessageType),
				slog.Int("metrics", len(payload.GetMetrics())),
			)
			return nil
		}
		// DATA — publish per-metric envelopes to edge.plc-normalized.<tenant>
		// for ADR-0008 comparator validation. If shadowpub failed to
		// initialize, fall back to log-only mode.
		if publisher != nil {
			if err := publisher.Publish(ctx, resolved); err != nil {
				logger.Warn("shadowpub: publish failed",
					slog.String("publisher", key.String()),
					slog.String("err", err.Error()))
				// don't fail the handler — keep alias table cursor advancing
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
