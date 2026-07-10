// ingest-shim — a small HTTPS→RabbitMQ ingress that lets a node in
// Incoplast's real Node-RED POST its SparkPlug-JSON payload over the public
// internet and have it republished VERBATIM onto the existing internal `oee`
// topic exchange (routing key `sparkplug.data`) — the same exchange +
// routing key oeecloud-worker already consumes.
//
// Why a shim at all: RabbitMQ stays internal (no public AMQP port, no broker
// creds handed to a third party). The shim is the only public surface; it
// authenticates the caller (X-Ingest-Key), scope-guards the payload to
// Incoplast data, then hands the bytes to the broker with publisher
// confirms so a POST only returns 202 once RabbitMQ has durably accepted
// the message.
//
// Flow once published:
//
//	Incoplast Node-RED --HTTPS POST--> ingest-shim --AMQP(confirm)-->
//	  oee exchange (sparkplug.data) --> oeecloud-worker --> F1/F3
//	  --> tenant-routed to enterprise 4 via seeded packml_register.
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/httpmetrics"
	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/httpserver"
	logp "github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/secrets"
	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/tracing"
)

func main() {
	// Docker healthcheck path. The runtime image is distroless (no shell,
	// no curl/wget), so the binary self-probes its own TLS /healthz.
	// Invoked via compose `healthcheck: ["CMD", "/usr/local/bin/ingest-shim", "--healthcheck"]`.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	logger := logp.Setup(cfg.LogLevel)

	// TLS is mandatory. We NEVER open a plaintext public listener — a shim
	// that accepts an API key over http:// would leak that key to any
	// on-path observer. Refuse to start if the cert/key pair is unset.
	if cfg.TLSCertFile == "" || cfg.TLSKeyFile == "" {
		logger.Error("refusing to start: TLS_CERT_FILE and TLS_KEY_FILE must both be set (no plaintext public listener)")
		os.Exit(1)
	}

	logger.Info("ingest-shim starting",
		slog.String("http_addr", cfg.HTTPAddr),
		slog.String("metrics_addr", cfg.MetricsAddr),
		slog.String("amqp_host", cfg.AMQPHost),
		slog.String("exchange", cfg.Exchange),
		slog.String("routing_key", cfg.RoutingKey),
		slog.String("scope_group", cfg.ScopeGroup),
		slog.Int64("max_body_bytes", cfg.MaxBodyBytes),
	)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Distributed tracing → Tempo. Opt-in: no-op unless OTEL_EXPORTER_OTLP_
	// ENDPOINT is set (see internal/tracing). The inbound server span is the
	// root of the ingest trace; phase 2 carries traceparent onto the AMQP
	// publish so oeecloud-worker's consume continues the same trace.
	shutdownTracing, terr := tracing.Init(ctx, "ingest-shim")
	if terr != nil {
		logger.Warn("tracing init failed; continuing untraced", slog.String("err", terr.Error()))
	}
	defer func() { _ = shutdownTracing(context.Background()) }()

	// Fetch the AMQP creds from Secrets Manager — same mechanism as
	// oeecloud-worker (least-privilege `oeecloud-worker` user, host/port
	// supplied here, username/password from the secret). CO-5: no plaintext
	// RABBITMQ_PASSWORD in compose env.
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

	m := metrics.New()

	// Publisher owns the AMQP connection + confirm-mode channel and heals
	// broker drops in the background.
	pub := amqp.NewPublisher(amqpCreds.URL(), cfg.Exchange, cfg.RoutingKey, cfg.ConfirmTimeout, logger)
	if err := pub.Connect(); err != nil {
		// Not fatal — the connection monitor keeps retrying and /healthz
		// reports unhealthy until the first successful dial. This lets the
		// shim start before the broker is reachable.
		logger.Warn("initial amqp connect failed, will retry in background", slog.String("err", err.Error()))
	}
	pub.StartConnectionMonitor(ctx)
	defer pub.Close()

	// Metrics server — plain HTTP on the internal-only :9105.
	metricsSrv := &http.Server{
		Addr:              cfg.MetricsAddr,
		Handler:           m.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		logger.Info("metrics server listening", slog.String("addr", cfg.MetricsAddr))
		if err := metricsSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("metrics server failed", slog.String("err", err.Error()))
		}
	}()

	// Public TLS API server.
	handler := httpserver.New(httpserver.Deps{
		APIKey:            cfg.IngestAPIKey,
		MaxBodyBytes:      cfg.MaxBodyBytes,
		ScopeGroup:        cfg.ScopeGroup,
		FanoutSourceTypes: cfg.FanoutSourceTypes,
		Publisher:         pub,
		Metrics:           m,
		Logger:            logger,
	})
	apiSrv := &http.Server{
		Addr: cfg.HTTPAddr,
		// otelhttp: a server span per request (trace root, continuing any inbound
		// traceparent). RED metrics wrap inside, recorded into m's registry,
		// which the :9105 metrics server already serves.
		Handler:           otelhttp.NewHandler(httpmetrics.New(m.Registerer())(handler), "ingest-shim"),
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}
	serveErr := make(chan error, 1)
	go func() {
		logger.Info("ingest API listening (TLS)", slog.String("addr", cfg.HTTPAddr))
		if err := apiSrv.ListenAndServeTLS(cfg.TLSCertFile, cfg.TLSKeyFile); err != nil && err != http.ErrServerClosed {
			serveErr <- err
		}
	}()

	select {
	case <-ctx.Done():
		logger.Info("shutdown signal received")
	case err := <-serveErr:
		logger.Error("api server failed", slog.String("err", err.Error()))
	}

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	_ = apiSrv.Shutdown(shutdownCtx)
	_ = metricsSrv.Shutdown(shutdownCtx)
	logger.Info("ingest-shim stopped")
}

// runHealthcheck performs an in-process HTTP GET of the shim's own /healthz
// over TLS (InsecureSkipVerify — the cert is the shim's own self-loop, not a
// trust decision). Exit 0 = healthy, non-zero = not. Mirrors the distroless
// self-probe pattern used by oeecloud-worker.
func runHealthcheck() int {
	cfg, err := config.LoadForHealthcheck()
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck config: %v\n", err)
		return 1
	}
	_, port, err := net.SplitHostPort(cfg.HTTPAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: bad HTTP_ADDR %q: %v\n", cfg.HTTPAddr, err)
		return 1
	}
	client := &http.Client{
		Timeout:   4 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}, //nolint:gosec // self-loop probe of our own listener
	}
	resp, err := client.Get(fmt.Sprintf("https://127.0.0.1:%s/healthz", port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
