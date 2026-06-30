// Package comparator owns the fidelity-watchdog loop (ADR-0008 phase 2a).
// The comparator SELECTs canonical values from BOTH prod and staging,
// computes divergence, emits Prometheus gauges. SELECT-only on both sides
// — never mutates either system. Differs from the reconciler (which writes
// to staging to close gaps) in being purely observational; together they
// form the writer + watchdog pair the comparator-service-as-fidelity-
// watchdog zettel describes.
//
// Phase 2a.1 (this commit) ships the skeleton + the cheapest metric:
// comparator_active_pos_diff (single COUNT(*) on each side, scoped per-
// enterprise). Future metrics from ADR-0008 (events_lag_seconds,
// oee_divergence_pct, dlq_anomaly_total, user_logs_lag) plug into the
// same RunOnce by adding measure-functions, no new loop machinery.
//
// Why a separate package vs adding to internal/reconcile/: the reconciler
// is a *writer* whose failure modes can corrupt staging state; the
// comparator is a *reader* whose failure modes only blind the watchdog.
// Different blast radius, different testing posture, different on-call
// implications. Splitting at the package boundary keeps that distinction
// auditable from import graphs.
package comparator

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
)

// Comparator owns the periodic fidelity-watchdog loop. One instance per
// worker process. Reuses the shared prodDB + stagingDB pools — no
// connection pressure beyond a single COUNT(*) per side per tick.
type Comparator struct {
	cfg     *config.Config
	prod    *db.Prod
	staging *db.Staging
	logger  *slog.Logger
}

func New(cfg *config.Config, prod *db.Prod, staging *db.Staging, logger *slog.Logger) *Comparator {
	return &Comparator{cfg: cfg, prod: prod, staging: staging, logger: logger}
}

// RunForever blocks until ctx is canceled. First pass fires immediately so
// a fresh worker emits the gauge without waiting the full interval — same
// shape as the reconcilers + DLQ retrier. Returns nil when the comparator
// is disabled via env so the host process's errgroup doesn't see a
// startup failure.
func (c *Comparator) RunForever(ctx context.Context) error {
	if !c.cfg.ComparatorEnabled {
		c.logger.Info("comparator disabled via COMPARATOR_ENABLED=false")
		return nil
	}
	interval := time.Duration(c.cfg.ComparatorIntervalSec) * time.Second
	c.logger.Info("comparator starting",
		slog.Int("interval_sec", c.cfg.ComparatorIntervalSec),
		slog.Int("prod_enterprise_id", c.cfg.ProdEnterpriseID),
		slog.Int("staging_enterprise_id", c.cfg.StagingEnterpriseID),
	)
	for {
		if err := c.RunOnce(ctx); err != nil {
			// Comparator tick failures are logged + counted but never
			// propagate — a transient prod hiccup shouldn't crash the
			// worker. Sustained failures are visible via the runs_total
			// counter ratio.
			c.logger.Warn("comparator tick failed", slog.String("err", err.Error()))
		}
		select {
		case <-time.After(interval):
		case <-ctx.Done():
			c.logger.Info("comparator stopping")
			return nil
		}
	}
}

// RunOnce executes a single comparator pass — one measurement per metric.
// Exported so future ad-hoc triggers (admin endpoint, signal handler) can
// drive it without waiting for the next tick. Returns the first error it
// encounters; downstream metrics for THIS tick are skipped on error.
//
// Phase 2a.1: only active_pos_diff. The pattern for adding 2a.2-2a.5 is:
// each new measurement is its own helper method that updates its own
// gauge + records its own outcome. Composition over a single mega-query
// keeps the per-metric failure mode legible.
func (c *Comparator) RunOnce(ctx context.Context) error {
	start := time.Now()
	if err := c.measureActivePOsDiff(ctx); err != nil {
		metrics.ComparatorRunsTotal.WithLabelValues("failed").Inc()
		return fmt.Errorf("active_pos_diff: %w", err)
	}
	metrics.ComparatorRunsTotal.WithLabelValues("ok").Inc()
	c.logger.Debug("comparator tick complete",
		slog.Duration("elapsed", time.Since(start)),
	)
	return nil
}

// measureActivePOsDiff queries both systems for count(active POs) within
// their respective enterprise scopes and updates the gauge with the diff.
// Healthy: 0. Positive: prod has more (staging behind on EnsureActivePOs).
// Negative: staging has more (stale rows that should have closed).
func (c *Comparator) measureActivePOsDiff(ctx context.Context) error {
	prodCount, err := c.prod.CountActivePOs(ctx, c.cfg.ProdEnterpriseID)
	if err != nil {
		return fmt.Errorf("prod count: %w", err)
	}
	stagingCount, err := c.staging.CountActivePOs(ctx, c.cfg.StagingEnterpriseID)
	if err != nil {
		return fmt.Errorf("staging count: %w", err)
	}
	diff := prodCount - stagingCount
	metrics.ComparatorActivePosDiff.Set(float64(diff))
	if diff != 0 {
		// Single info-level log per non-zero tick — enough signal to
		// investigate without spamming when healthy. Sustained non-zero
		// is the alert; transient blips read as fine on Grafana.
		c.logger.Info("comparator active_pos_diff non-zero",
			slog.Int("prod_count", prodCount),
			slog.Int("staging_count", stagingCount),
			slog.Int("diff", diff),
		)
	}
	return nil
}
