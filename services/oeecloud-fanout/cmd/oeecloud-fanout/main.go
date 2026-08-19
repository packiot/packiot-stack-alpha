// oeecloud-fanout — re-tenant twin fan-out (roadmap P1 / task #17).
//
// It makes the STAGING sandbox tenant SBXCPACK (enterprise 2000003) a faithful
// ALL-LINES twin of the real CPACK tenant (enterprise 3) by fanning out
// staging's live CPACK decoded SparkPlug stream, re-tenanting each message
// (CPACK/… → SBXCPACK/…, clearing inherited equipment ids), and republishing it
// on the twin's routing key so the sandbox's oeecloud-worker queue
// (oeecloud-worker-q-sbxcpack) writes SBXCPACK F3 rows.
//
// Flag-gated: does nothing unless FANOUT_CPACK_TO_SBXCPACK_ENABLED=true. Wired
// into compose.staging.yml ONLY — never prod. See the amqp + retenant packages
// for the double-count / no-loop reasoning.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"log/slog"

	fanoutamqp "github.com/packiot/packiot-stack-alpha/services/oeecloud-fanout/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-fanout/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-fanout/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/oeecloud-fanout/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-fanout/internal/secrets"
)

func main() {
	// Docker healthcheck subcommand — distroless has no shell/curl.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	cfg := config.Load()
	logger := logp.Setup(cfg.LogLevel)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Disabled → serve /health (healthy) and idle. Enabling is a pure .env flip
	// + restart; no queue is bound and nothing is consumed while off.
	if !cfg.Enabled {
		logger.Info("oeecloud-fanout DISABLED (FANOUT_CPACK_TO_SBXCPACK_ENABLED != true) — idling",
			slog.Int("health_port", cfg.HealthPort))
		hs := health.New(fmt.Sprintf(":%d", cfg.HealthPort), idleSnapshot{}, logger)
		hs.Start()
		<-ctx.Done()
		shutdownCtx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		_ = hs.Shutdown(shutdownCtx)
		return
	}

	logger.Info("oeecloud-fanout starting",
		slog.String("amqp_host", cfg.AMQPHost),
		slog.String("queue", cfg.FanoutQueue),
		slog.String("source_group", cfg.SourceGroup),
		slog.String("target_group", cfg.TargetGroup),
		slog.String("target_routing_key", cfg.TargetRoutingKey),
		slog.Int("health_port", cfg.HealthPort))

	secretsCtx, secretsCancel := context.WithTimeout(ctx, 10*time.Second)
	defer secretsCancel()
	amqpCreds, err := secrets.FetchAMQPCreds(secretsCtx, cfg.AWSRegion, cfg.RabbitMQSecretID, cfg.AMQPHost, cfg.AMQPPort)
	if err != nil {
		logger.Error("fetch rabbitmq secret failed",
			slog.String("err", err.Error()),
			slog.String("secret_id", cfg.RabbitMQSecretID))
		os.Exit(1)
	}
	logger.Info("secrets fetched", slog.String("amqp", amqpCreds.Redacted()))

	f := fanoutamqp.NewFanout(cfg, amqpCreds.URL(), logger)

	hs := health.New(fmt.Sprintf(":%d", cfg.HealthPort), f, logger)
	hs.Start()

	runErr := f.Run(ctx)

	shutdownCtx, c := context.WithTimeout(context.Background(), 5*time.Second)
	defer c()
	_ = hs.Shutdown(shutdownCtx)

	if runErr != nil && runErr != context.Canceled {
		logger.Error("fanout exited with error", slog.String("err", runErr.Error()))
		os.Exit(1)
	}
	logger.Info("oeecloud-fanout stopped")
}

// idleSnapshot is the /health body while the service is disabled: always
// healthy so the container passes its healthcheck without doing any work.
type idleSnapshot struct{}

func (idleSnapshot) Snapshot() ([]byte, bool, error) {
	body, _ := json.Marshal(map[string]any{"healthy": true, "enabled": false})
	return body, true, nil
}

// runHealthcheck GETs the in-process /health and returns 0 iff healthy=true.
func runHealthcheck() int {
	port := 9102
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
