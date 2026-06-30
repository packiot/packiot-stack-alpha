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
	"strconv"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
)

// Comparator owns the periodic fidelity-watchdog loop. One instance per
// worker process. Reuses the shared prodDB + stagingDB pools — no
// connection pressure beyond a single COUNT(*) per side per tick.
//
// lastOEERun gates the heavy OEE divergence measurement to its own
// (longer) cadence. It's not protected by a mutex because RunOnce is
// only called from a single goroutine inside RunForever — the comparator
// loop is single-threaded by design (no fanout into per-metric goroutines
// because the per-tick query budget is tiny).
type Comparator struct {
	cfg     *config.Config
	prod    *db.Prod
	staging *db.Staging
	logger  *slog.Logger

	lastOEERun time.Time
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
// drive it without waiting for the next tick.
//
// Each measure-function is independent: a failure in one does NOT short-
// circuit the rest. This is the key composition property — a transient
// prod hiccup on equipment_events shouldn't blind the active_pos_diff
// signal, or vice versa. Per-measurement errors are logged + counted via
// the runs counter; the tick-level outcome is "ok" if at least one
// measurement landed, "failed" only if every measurement errored.
//
// Phase 2a.1: active_pos_diff. Phase 2a.2 (this commit): + events_lag_seconds,
// + user_logs_lag. Phase 2a.3-2a.5 add the heavier metrics + Grafana wiring.
func (c *Comparator) RunOnce(ctx context.Context) error {
	start := time.Now()
	var ok, failed int

	if err := c.measureActivePOsDiff(ctx); err != nil {
		failed++
		c.logger.Warn("comparator measure failed", slog.String("metric", "active_pos_diff"), slog.String("err", err.Error()))
	} else {
		ok++
	}
	if err := c.measureEventsLagSeconds(ctx); err != nil {
		failed++
		c.logger.Warn("comparator measure failed", slog.String("metric", "events_lag_seconds"), slog.String("err", err.Error()))
	} else {
		ok++
	}
	if err := c.measureUserLogsLag(ctx); err != nil {
		failed++
		c.logger.Warn("comparator measure failed", slog.String("metric", "user_logs_lag"), slog.String("err", err.Error()))
	} else {
		ok++
	}
	// OEE divergence runs on its own (longer) cadence — internal gate, not
	// a separate goroutine. Skip silently when not due; emit logs when run.
	// First tick after boot always runs (zero-value lastOEERun is far enough
	// in the past).
	if time.Since(c.lastOEERun) >= time.Duration(c.cfg.ComparatorOEEIntervalSec)*time.Second {
		if err := c.measureOEEDivergence(ctx); err != nil {
			failed++
			c.logger.Warn("comparator measure failed", slog.String("metric", "oee_divergence_pct"), slog.String("err", err.Error()))
		} else {
			ok++
		}
		c.lastOEERun = time.Now()
	}

	// Tick outcome: ok if any measurement landed, failed only if all errored.
	// The runs counter is a coarse tick-level signal — the per-metric gauges
	// are the actionable values; this counter exists to flag "watchdog is
	// blind" outages where every measurement is dying at once.
	if ok == 0 && failed > 0 {
		metrics.ComparatorRunsTotal.WithLabelValues("failed").Inc()
	} else {
		metrics.ComparatorRunsTotal.WithLabelValues("ok").Inc()
	}
	c.logger.Debug("comparator tick complete",
		slog.Int("measures_ok", ok),
		slog.Int("measures_failed", failed),
		slog.Duration("elapsed", time.Since(start)),
	)
	// Return nil unconditionally so RunForever's loop continues — per-tick
	// failures are surfaced via metrics + logs, not via the returned error.
	// Returning err here would only show up in tick-failed logs which are
	// less actionable than the per-measure WARN above.
	return nil
}

// measureOEEDivergence walks the active mapped POs, fetches prod's
// net_production in a single round-trip via the existing
// FetchRuntimeValues helper, and emits abs(prod-staging)/prod per PO.
//
// Label management: Reset()s the GaugeVec at the start of each pass so
// labels for now-finished POs drop off automatically. Per-PO cardinality
// stays bounded by the active set (~10-15 typical). The "metric briefly
// disappears between Reset and Set" race is invisible at 30-min cadence
// + 15s scrape — Prometheus catches a populated vec every time.
//
// Math (per PO):
//   - prodNet nil or 0  → skip (can't compute pct without a denominator)
//   - stagingNet nil    → treat as 0 (PO mapped but no runtime row yet)
//   - else              → divergence = abs(prodNet - stagingNet) / prodNet
//
// Per-PO outcome counters give the dashboard separation between
// "everyone healthy" and "we measured nothing because every PO is freshly
// started" vs "the measure errored entirely".
func (c *Comparator) measureOEEDivergence(ctx context.Context) error {
	mapped, err := c.staging.FetchMappedActiveCPACKPOs(ctx, c.cfg.SourceName, c.cfg.StagingEnterpriseID)
	if err != nil {
		return fmt.Errorf("fetch mapped active POs: %w", err)
	}
	if len(mapped) == 0 {
		// No active POs → nothing to compare. Reset the vec so any stale
		// labels from a prior tick disappear. Healthy state: 0 active POs
		// means the line is idle, which is real information for dashboards.
		metrics.ComparatorOEEDivergencePct.Reset()
		c.logger.Debug("comparator oee_divergence: no active POs — vec reset, nothing to emit")
		return nil
	}

	prodIDs := make([]int64, 0, len(mapped))
	for _, m := range mapped {
		prodIDs = append(prodIDs, m.ProdPOID)
	}
	prodRuntimes, err := c.prod.FetchRuntimeValues(ctx, prodIDs)
	if err != nil {
		return fmt.Errorf("fetch prod runtime values: %w", err)
	}

	// Reset vec so labels for finished POs (no longer in `mapped`) drop off.
	// Then set labels for currently-active POs.
	metrics.ComparatorOEEDivergencePct.Reset()
	var emitted, skipped int
	for _, m := range mapped {
		prodVals, prodFound := prodRuntimes[m.ProdPOID]
		divergence, ok := computeOEEDivergence(prodVals, prodFound, m.StagingNetProduction)
		if !ok {
			skipped++
			metrics.ComparatorOEEMeasured.WithLabelValues("skipped").Inc()
			continue
		}
		// Label uses the staging PO id (the side the operator UI shows).
		// Using prod PO id would force operators to look up the mapping
		// every time they investigate a divergence; staging id is the one
		// they already see on dashboards.
		labelVal := strconv.FormatInt(m.StagingPOID, 10)
		metrics.ComparatorOEEDivergencePct.WithLabelValues(labelVal).Set(divergence)
		metrics.ComparatorOEEMeasured.WithLabelValues("ok").Inc()
		emitted++
		// Only log when divergence exceeds an attention threshold —
		// keeps the per-tick log volume tiny on the healthy path.
		if divergence > 0.05 {
			c.logger.Info("comparator oee_divergence above 5%",
				slog.Int64("prod_po", m.ProdPOID),
				slog.Int64("staging_po", m.StagingPOID),
				slog.Float64("divergence_pct", divergence),
				slog.Float64("prod_net", *prodVals.NetProduction),
				slog.Float64("staging_net", floatOrZero(m.StagingNetProduction)),
			)
		}
	}
	c.logger.Info("comparator oee_divergence tick complete",
		slog.Int("emitted", emitted),
		slog.Int("skipped", skipped),
		slog.Int("active_pos", len(mapped)),
	)
	return nil
}

// computeOEEDivergence is the pure-function math the measure delegates to.
// Exposed at package-private scope (lowercase) so the unit tests can pin
// the edge cases without touching the DB. Returns (pct, ok) where ok=false
// means "skip this label — input is undefined for divergence pct".
func computeOEEDivergence(prod db.ProdRuntimeValues, prodFound bool, stagingNet *float64) (float64, bool) {
	if !prodFound || prod.NetProduction == nil || *prod.NetProduction == 0 {
		// No denominator → divergence_pct undefined. The reasons differ
		// (PO missing from prod runtime table vs PO freshly started with
		// no production yet) but the outcome for the gauge is the same:
		// skip the label this tick.
		return 0, false
	}
	staging := floatOrZero(stagingNet)
	diff := *prod.NetProduction - staging
	if diff < 0 {
		diff = -diff
	}
	return diff / *prod.NetProduction, true
}

func floatOrZero(p *float64) float64 {
	if p == nil {
		return 0
	}
	return *p
}

// measureEventsLagSeconds queries both systems for max(ts_event) over the
// last hour and updates the gauge with the lag in seconds (prod - staging).
// Skips emission when prod has no recent events (zero time returned) —
// avoids logging a false-positive lag when the line is simply idle.
// Healthy: < 120s (events reconciler cadence is 60s; one tick of lag is
// normal). > 300s sustained means the events-sync reconciler is stuck or
// disabled.
func (c *Comparator) measureEventsLagSeconds(ctx context.Context) error {
	prodTs, err := c.prod.MaxRecentEventTs(ctx, c.cfg.ProdEnterpriseID)
	if err != nil {
		return fmt.Errorf("prod max ts_event: %w", err)
	}
	if prodTs.IsZero() {
		// No prod activity in the window → no signal to emit. Don't update
		// the gauge; existing reading stays until the next non-empty tick.
		c.logger.Debug("comparator events_lag: prod side empty in last hour — skipping emission")
		return nil
	}
	stagingTs, err := c.staging.MaxRecentEventTs(ctx, c.cfg.StagingEnterpriseID)
	if err != nil {
		return fmt.Errorf("staging max ts_event: %w", err)
	}
	if stagingTs.IsZero() {
		// Prod has events but staging doesn't — full reconciler failure.
		// Surface as a huge lag (window cap) so dashboards flag it.
		c.logger.Warn("comparator events_lag: staging side empty in last hour while prod has events",
			slog.Time("prod_max", prodTs))
		metrics.ComparatorEventsLagSeconds.Set(3600) // cap = window size
		return nil
	}
	lag := prodTs.Sub(stagingTs).Seconds()
	metrics.ComparatorEventsLagSeconds.Set(lag)
	if lag > 300 {
		c.logger.Info("comparator events_lag above threshold",
			slog.Time("prod_max", prodTs),
			slog.Time("staging_max", stagingTs),
			slog.Float64("lag_sec", lag))
	}
	return nil
}

// measureUserLogsLag queries prod for max(user_logs.id_user_logs) and
// compares to the worker's mirror_replay_cursor.last_log_id. Result is
// the count of unprocessed prod user_logs IDs ahead of the worker.
// Healthy: tiny (the cursor advances on every poll tick; lag is bounded
// by the prod publish rate during the tick interval). Large sustained
// values mean the worker has stalled.
func (c *Comparator) measureUserLogsLag(ctx context.Context) error {
	prodMax, err := c.prod.MaxUserLogID(ctx, c.cfg.ProdEnterpriseID)
	if err != nil {
		return fmt.Errorf("prod max user_logs id: %w", err)
	}
	stagingCursor, err := c.staging.ReadCursor(ctx, c.cfg.SourceName)
	if err != nil {
		return fmt.Errorf("staging cursor read: %w", err)
	}
	lag := prodMax - stagingCursor
	metrics.ComparatorUserLogsLag.Set(float64(lag))
	if lag > 100 {
		// 100 is generous — at prod's ~1 user_log every few seconds, lag >100
		// means the worker is well over a minute behind. Worth a log line for
		// pattern analysis even before the alert threshold.
		c.logger.Info("comparator user_logs_lag elevated",
			slog.Int64("prod_max", prodMax),
			slog.Int64("staging_cursor", stagingCursor),
			slog.Int64("lag", lag))
	}
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
