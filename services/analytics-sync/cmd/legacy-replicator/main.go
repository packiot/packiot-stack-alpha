// legacy-replicator — cross-instance twin replicator. Replays CPACK
// operator actions from the LEGACY prod DB (packiot40, enterprise 1) into
// the staging analytics plane (packiot_analytics, enterprise 3) so staging
// is a faithful TWIN of what factory operators do live.
//
// It is a sibling of analytics-sync (shadow-mirror): same poll/cursor/
// dispatch philosophy and idempotent natural-key writes, plus an id-mapping
// layer at the boundary (see internal/replicate/resolver.go). The source DB
// is SELECT-only; every write and the cursor live in staging.
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
	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/replicate"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	cfg := replicate.Load()
	logger := logp.Setup(cfg.LogLevel)
	m := metrics.New()

	if !cfg.Enabled {
		logger.Info("REPLICATE_ENABLED=false — legacy-replicator idle (no-op mode)")
		serveHTTP(cfg.HealthPort, m, logger)
		return
	}
	if cfg.LegacyPassword == "" || cfg.DestPassword == "" {
		logger.Error("LEGACY_DB_PASSWORD / DEST_DB_PASSWORD required — refusing to boot")
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// SOURCE pool — legacy prod, SELECT-only. Natural-key resolution only.
	legacyCreds := &db.DBCreds{Host: cfg.LegacyHost, Port: cfg.LegacyPort, User: cfg.LegacyUser, Password: cfg.LegacyPassword}
	legacyPool, err := db.NewPool(ctx, legacyCreds, cfg.LegacyDBName, "legacy-replicator-src", logger)
	if err != nil {
		logger.Error("legacy pool init failed", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer legacyPool.Close()

	// DEST pool — staging analytics. All writes + cursor.
	destCreds := &db.DBCreds{Host: cfg.DestHost, Port: cfg.DestPort, User: cfg.DestUser, Password: cfg.DestPassword}
	destPool, err := db.NewPool(ctx, destCreds, cfg.DestDBName, "legacy-replicator-dst", logger)
	if err != nil {
		logger.Error("dest pool init failed", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer destPool.Close()

	resolver, err := replicate.BuildResolver(ctx, legacyPool, destPool, cfg.SrcEnterprise, cfg.DstEnterprise, logger)
	if err != nil {
		logger.Error("build resolver failed", slog.String("err", err.Error()))
		os.Exit(1)
	}

	// Zero-row UPDATEs are replay gaps that must be observable (bugs 247/248 class).
	replicate.SetNoopObserver(func(table string) { m.IncUpdateNoop("public", table) })

	d := replicate.NewDispatcher(logger)
	d.Register("downtime-event-created", replicate.DowntimeEventCreated(logger, cfg.ReplicateBaseEvents))
	d.Register("event-justified", replicate.EventClassified(logger))
	d.Register("event-edited", replicate.EventClassified(logger))
	d.Register("manual-event-created", replicate.ManualEventCreated(logger))
	d.Register("manual-event-edited", replicate.ManualEventEdited(logger))
	d.Register("event-splitted", replicate.EventSplitted(logger))
	d.Register("order-created", replicate.OrderCreated(logger))
	d.Register("order-created-started", replicate.OrderCreatedStarted(logger))
	d.Register("order-started", replicate.OrderStarted(logger))
	d.Register("order-stopped", replicate.OrderStopped(logger))
	d.Register("order-time-changed", replicate.OrderTimeChanged(logger))
	d.Register("order-replaced", replicate.OrderRecalc(logger))
	d.Register("order-status-changed", replicate.OrderRecalc(logger))
	d.Register("order-changed", replicate.OrderChanged(logger))

	// Heartbeat-backed healthcheck: the loop beats after every successful poll;
	// /healthz flips to 503 once the last beat is older than HEALTHCHECK_MAX_AGE_SEC
	// so the docker healthcheck can catch a wedged loop (a plain 200 cannot).
	checker := health.NewChecker("legacy-replicator", time.Duration(cfg.HealthMaxAgeSec)*time.Second)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", checker.Handler())
	mux.Handle("/metrics", m.Handler())
	go func() {
		addr := fmt.Sprintf(":%d", cfg.HealthPort)
		logger.Info("http server", slog.String("addr", addr))
		if err := http.ListenAndServe(addr, mux); err != nil && err != http.ErrServerClosed {
			logger.Error("http server error", slog.String("err", err.Error()))
		}
	}()

	// PO reconciler — authoritative production_orders backfill/finish loop that
	// closes the gap the user_logs replay structurally can't (POs started via
	// order-changed's non-create branch + PLC-created POs never hit user_logs).
	// Ships INERT (RECONCILE_PO_ENABLED=false); runs in its own goroutine.
	poRecon := replicate.NewPOReconciler(legacyPool, destPool, resolver, cfg, m, logger)
	go func() {
		if err := poRecon.RunForever(ctx); err != nil && ctx.Err() == nil {
			logger.Error("PO reconciler terminated with error", slog.String("err", err.Error()))
		}
	}()

	if err := replicate.Loop(ctx, legacyPool, destPool, resolver, d, m, cfg, checker.Beat, logger); err != nil {
		if ctx.Err() != nil {
			logger.Info("shutting down (ctx cancelled)")
			return
		}
		logger.Error("loop terminated with error", slog.String("err", err.Error()))
		os.Exit(1)
	}
}

func serveHTTP(port int, m *metrics.Metrics, logger *slog.Logger) {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", health.Handler())
	mux.Handle("/metrics", m.Handler())
	addr := fmt.Sprintf(":%d", port)
	logger.Info("http server (idle mode)", slog.String("addr", addr))
	if err := http.ListenAndServe(addr, mux); err != nil {
		logger.Error("http server error", slog.String("err", err.Error()))
	}
}

func runHealthcheck() int {
	port := 9104
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
