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
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/handlers"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/log"
)

func main() {
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

	// Postgres pool. Declared but no handlers use it yet (placeholder
	// LogOnly only acks). Wired in advance so adding the first real
	// handler next session is a one-import change.
	//
	// NOTE: commented out for the scaffold-only commit — the pgx import
	// adds ~5 MB to the binary and we don't need it until a real handler
	// lands. Uncomment together with the first real handler.
	//
	// pool, err := db.New(ctx, cfg, logger)
	// if err != nil {
	//     logger.Error("postgres pool init failed", slog.String("err", err.Error()))
	//     os.Exit(1)
	// }
	// defer pool.Close()

	dispatcher := handlers.NewDispatcher(logger)
	// Future: dispatcher.Register("sparkplug.equipment_values", writers.NewEquipmentValuesHandler(pool, logger))

	consumer := amqp.NewConsumer(cfg, dispatcher, logger)

	healthSrv := health.New(
		fmt.Sprintf(":%d", cfg.HealthPort),
		snapshotAdapter{consumer: consumer},
		logger,
	)
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

// snapshotAdapter implements health.Snapshotter by returning the
// consumer's Snapshot struct as `any` (so health pkg stays unaware of
// consumer-specific shape).
type snapshotAdapter struct {
	consumer *amqp.Consumer
}

func (a snapshotAdapter) Snapshot() any { return a.consumer.Snapshot() }
