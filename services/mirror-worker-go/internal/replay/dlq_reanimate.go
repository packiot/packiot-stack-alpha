package replay

// dlq_reanimate.go — periodic re-arming of mirror_replay_dlq rows that
// exhausted retry_attempts but became newly mappable later.
//
// Why this loop exists (separate from dlq_retry.go's loop): the
// DLQRetrier caps retries at DLQ_RETRY_MAX_ATTEMPTS (default 5) so
// permanently-broken rows don't churn forever. Industry-standard DLQ
// design — see AWS SQS maxReceiveCount, Kafka retry-topic chains,
// Stripe webhook retries. The cap is correct.
//
// But the cap interacts badly with the events reconciler's cold-start
// backlog. The matcher catches up to a stuck event ID hours or days
// after the user_logs replay first hit the DLQ — by which point the
// retry counter is long past the cap and the entry sits forever
// despite the underlying translation now succeeding. Session 69 found
// 35 such rows: all event-* operator actions, all retry_attempts=5,
// all targeting prod equipment_event IDs ~35M above the reconciler's
// current cursor at the time they were DLQ'd.
//
// The reanimator runs once every DLQ_REANIMATE_INTERVAL_SEC (default
// 10 min) and resets retry_attempts=0 + last_retry_at=NULL on rows
// whose prod_id is NOW present in mirror_id_map. The next tick of the
// existing DLQRetrier picks them up via the standard eligibility
// window. The DLQRetrier's logic is unchanged — we just edit the
// counter that gates its loop. Atomic UPDATE-RETURNING; no double-tx
// gymnastics; pure data-plane operation.
//
// Scope: equipment_event-shaped categories only — today that means
// downtime-event-created. (event-justified, event-edited, event-splitted
// are no longer registered handlers; the events-sync reconciler is the
// sole writer of equipment_events.) Order-* categories carry
// idProductionOrder and need a sibling predicate — none stuck today,
// so deferred until they actually appear.
//
// What this is NOT: NOT a way to bypass retry caps for genuinely-
// broken rows. The mappability predicate is the gate; if the source
// translation still fails (equipment missing, payload malformed,
// permanent dead-letter shape), the row stays at retry_attempts=cap
// and continues to surface in human-triage queries.

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
)

// DLQReanimator owns the periodic reanimate loop. One instance per
// worker process. Shares the staging pool with the rest of the worker —
// the UPDATE is a single round-trip per tick, no connection pressure.
type DLQReanimator struct {
	cfg     *config.Config
	staging *db.Staging
	logger  *slog.Logger
}

func NewDLQReanimator(cfg *config.Config, staging *db.Staging, logger *slog.Logger) *DLQReanimator {
	return &DLQReanimator{cfg: cfg, staging: staging, logger: logger}
}

// RunForever blocks until ctx is canceled. First pass fires immediately
// so a fresh worker drains any already-mappable backlog without waiting
// the full interval — same shape as DLQRetrier.RunForever.
func (r *DLQReanimator) RunForever(ctx context.Context) error {
	if !r.cfg.DLQReanimateEnabled {
		r.logger.Info("DLQ reanimate disabled via DLQ_REANIMATE_ENABLED=false")
		return nil
	}
	interval := time.Duration(r.cfg.DLQReanimateIntervalSec) * time.Second
	r.logger.Info("DLQ reanimate starting",
		slog.Int("interval_sec", r.cfg.DLQReanimateIntervalSec),
		slog.Int("batch_size", r.cfg.DLQReanimateBatchSize),
	)
	for {
		if err := r.RunOnce(ctx); err != nil {
			r.logger.Warn("DLQ reanimate tick failed", slog.String("err", err.Error()))
		}
		select {
		case <-time.After(interval):
		case <-ctx.Done():
			r.logger.Info("DLQ reanimate stopping")
			return nil
		}
	}
}

// RunOnce executes one reanimate pass. Exported so future ad-hoc
// triggers (admin endpoint, signal handler) can drive it without
// waiting for the next tick.
//
// Returns nil even when no rows were reanimated — a "nothing to do"
// tick is the healthy steady state.
func (r *DLQReanimator) RunOnce(ctx context.Context) error {
	start := time.Now()
	ids, err := r.staging.ReanimateMappableEquipmentEventDLQ(ctx,
		r.cfg.SourceName,
		r.cfg.DLQRetryMaxAttempts,
		r.cfg.DLQReanimateBatchSize)
	if err != nil {
		return fmt.Errorf("reanimate DLQ: %w", err)
	}
	if len(ids) == 0 {
		// Healthy steady state — quiet log to avoid polluting the stream
		// every 10 min.
		r.logger.Debug("DLQ reanimate tick — nothing to reanimate",
			slog.Duration("elapsed", time.Since(start)))
		return nil
	}
	metrics.DLQReanimatedTotal.Add(float64(len(ids)))
	r.logger.Info("DLQ reanimate tick complete — entries reset to retry_attempts=0",
		slog.Int("reanimated", len(ids)),
		slog.Any("dlq_ids", ids),
		slog.Duration("elapsed", time.Since(start)))
	return nil
}
