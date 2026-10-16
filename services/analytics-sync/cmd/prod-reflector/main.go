// prod-reflector — keeps a staging tenant an exact, read-only mirror of the same tenant in production
// (ADR-0064). Production is the single source of truth after a tenant's production go-live; staging keeps its own
// PLC reader for the raw series but takes everything else (configuration, users, production orders, events and
// their justifications, box scans, samples, OEE) from production, every minute.
//
// IDLE unless PROD_MIRROR_ENTERPRISES is set — the same one-line switch that makes edge-api, barcode-service and
// stream-engine treat the tenant as a mirror. Idle = no DB connection and no secret read.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/mirror"
	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/replicate"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}
	cfg, err := mirror.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "prod-reflector config:", err)
		os.Exit(1)
	}
	logger := logp.Setup(cfg.LogLevel)
	m := mirror.NewMetrics()

	if !cfg.Enabled() {
		logger.Info("PROD_MIRROR_ENTERPRISES is empty — prod-reflector idle (no DB connection)")
		serve(cfg.HealthPort, health.Handler(), m, logger)
		return
	}
	m.Enabled.Set(1)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	src, err := mirror.LoadCreds(ctx, "SRC_SECRET_ID", "SRC", replicate.AWSSecret)
	if err != nil {
		logger.Error("production (source) credentials", slog.String("err", err.Error()))
		os.Exit(1)
	}
	dst, err := mirror.LoadCreds(ctx, "PG_SECRET_ID", "DEST", replicate.AWSSecret)
	if err != nil {
		logger.Error("staging (destination) credentials", slog.String("err", err.Error()))
		os.Exit(1)
	}
	if src.User != mirror.SrcRole {
		logger.Warn("production login is not the read-only role", slog.String("user", src.User), slog.String("want", mirror.SrcRole))
	}
	if dst.User != mirror.DstRole {
		logger.Warn("staging login is not the least-privilege role", slog.String("user", dst.User), slog.String("want", mirror.DstRole))
	}

	checker := health.NewChecker("prod-reflector", time.Duration(cfg.HealthMaxAgeSec)*time.Second)
	go serve(cfg.HealthPort, checker.Handler(), m, logger)

	done := make(chan struct{}, len(cfg.Enterprises))
	for _, ent := range cfg.Enterprises {
		// Each connection is stamped with the tenant (RLS: a connection without the stamp sees no tenant rows, so
		// production would look EMPTY — the empty_source guard refuses to delete on that), UTC (jsonb text of
		// timestamps must be identical on both sides) and, on production, read-only.
		stamp := map[string]string{"app.tenant_id": strconv.Itoa(ent), "TimeZone": "UTC"}
		srcPool, err := db.NewPool(ctx, &db.DBCreds{Host: src.Host, Port: src.Port, User: src.User, Password: src.Password,
			Params: map[string]string{"app.tenant_id": strconv.Itoa(ent), "TimeZone": "UTC", "default_transaction_read_only": "on"}},
			src.Database, "prod-reflector-src", logger)
		if err != nil {
			logger.Error("production pool", slog.Int("enterprise", ent), slog.String("err", err.Error()))
			os.Exit(1)
		}
		dstPool, err := db.NewPool(ctx, &db.DBCreds{Host: dst.Host, Port: dst.Port, User: dst.User, Password: dst.Password,
			Params: stamp}, dst.Database, "prod-reflector-dst", logger)
		if err != nil {
			logger.Error("staging pool", slog.Int("enterprise", ent), slog.String("err", err.Error()))
			os.Exit(1)
		}
		r := mirror.NewReflector(cfg, ent, srcPool, dstPool, m, logger)
		logger.Info("reflecting production → staging", slog.Int("enterprise", ent), slog.Bool("dry_run", cfg.DryRun),
			slog.Duration("interval", cfg.Interval), slog.Int("lookback_days", cfg.LookbackDays))
		go func() {
			defer func() { done <- struct{}{} }()
			_ = r.RunForever(ctx, checker.Beat)
		}()
	}
	<-ctx.Done()
	for range cfg.Enterprises {
		<-done
	}
}

func serve(port int, h http.HandlerFunc, m *mirror.Metrics, logger *slog.Logger) {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", h)
	mux.Handle("/metrics", m.Handler())
	addr := fmt.Sprintf(":%d", port)
	logger.Info("http server", slog.String("addr", addr))
	if err := http.ListenAndServe(addr, mux); err != nil && err != http.ErrServerClosed {
		logger.Error("http server error", slog.String("err", err.Error()))
	}
}

func runHealthcheck() int {
	port := 9124
	if p := os.Getenv("HEALTH_PORT"); p != "" {
		if n, err := strconv.Atoi(p); err == nil {
			port = n
		}
	}
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get(fmt.Sprintf("http://127.0.0.1:%d/healthz", port))
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
