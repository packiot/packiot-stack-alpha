package replay

// dlq_retry.go — periodic re-replay of mirror_replay_dlq rows that
// failed the first time (or last time) with a transient error.
//
// Why: the main poll loop writes a DLQ row + advances the cursor on any
// non-skip error. That keeps the queue moving but every failed row
// previously needed a human to inspect + re-replay. Most failures are
// transient (edge-api connection refused during a deploy bounce, brief
// prod hiccup, race between two events on the same entity) and would
// succeed if simply retried a minute or five later.
//
// Loop shape (mirrors the reconcilers — periodic, bounded per pass):
//   1. SELECT mirror_replay_dlq rows past their backoff window (db).
//   2. For each: re-SELECT the prod user_log by source_log_id; build a
//      synthetic ProdUserLog; dispatch through the existing handler.
//   3. On success: DELETE the DLQ row inside the same staging tx the
//      replay used.
//   4. On failure: UPDATE retry_attempts + last_retry_at on the DLQ row
//      so the backoff window slides for the next pass.
//
// Sole-writer-of-DLQ-bookkeeping invariant: only this retrier touches
// retry_attempts + last_retry_at. The main loop's WriteDLQ leaves them
// at their column defaults (0 / NULL) so first retry fires immediately.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
)

// DLQRetrier owns the periodic retry loop. One instance per worker
// process. Reuses the dispatcher so retried rows take the exact same
// code path as a first-attempt replay — no shadow handler set to drift.
type DLQRetrier struct {
	cfg     *config.Config
	prod    *db.Prod
	staging *db.Staging
	disp    *Dispatcher
	logger  *slog.Logger
}

func NewDLQRetrier(cfg *config.Config, prod *db.Prod, staging *db.Staging, disp *Dispatcher, logger *slog.Logger) *DLQRetrier {
	return &DLQRetrier{cfg: cfg, prod: prod, staging: staging, disp: disp, logger: logger}
}

// RunForever blocks until ctx is canceled. First pass fires immediately
// so a fresh worker doesn't wait the full interval before draining the
// existing DLQ backlog.
func (r *DLQRetrier) RunForever(ctx context.Context) error {
	if !r.cfg.DLQRetryEnabled {
		r.logger.Info("DLQ retry disabled via DLQ_RETRY_ENABLED=false")
		return nil
	}
	interval := time.Duration(r.cfg.DLQRetryIntervalSec) * time.Second
	r.logger.Info("DLQ retry starting",
		slog.Int("interval_sec", r.cfg.DLQRetryIntervalSec),
		slog.Int("max_attempts", r.cfg.DLQRetryMaxAttempts),
		slog.Int("batch_size", r.cfg.DLQRetryBatchSize),
	)
	for {
		if err := r.RunOnce(ctx); err != nil {
			r.logger.Warn("DLQ retry tick failed", slog.String("err", err.Error()))
		}
		select {
		case <-time.After(interval):
		case <-ctx.Done():
			r.logger.Info("DLQ retry stopping")
			return nil
		}
	}
}

// RunOnce executes one retry pass. Exported so future ad-hoc triggers
// (admin endpoint, signal handler) can drive it without waiting for
// the next tick.
func (r *DLQRetrier) RunOnce(ctx context.Context) error {
	start := time.Now()
	// Refresh the depth gauge every tick — cheap and the dashboard
	// reads from it. Best-effort: failure here is logged but doesn't
	// fail the pass.
	if n, err := r.staging.CountDLQ(ctx, r.cfg.SourceName); err == nil {
		metrics.DLQDepth.Set(float64(n))
	}

	rows, err := r.staging.FetchRetriableDLQ(ctx, r.cfg.SourceName, r.cfg.DLQRetryMaxAttempts, r.cfg.DLQRetryBatchSize)
	if err != nil {
		return fmt.Errorf("fetch retriable DLQ: %w", err)
	}
	if len(rows) == 0 {
		return nil
	}

	var succeeded, failed, permanent, terminal int
	for _, row := range rows {
		switch outcome := r.retryOne(ctx, row); outcome {
		case "succeeded":
			succeeded++
			metrics.DLQRetryAttemptsTotal.WithLabelValues("succeeded").Inc()
		case "failed":
			failed++
			metrics.DLQRetryAttemptsTotal.WithLabelValues("failed").Inc()
		case "permanent":
			permanent++
			metrics.DLQRetryAttemptsTotal.WithLabelValues("permanent").Inc()
		case "terminal":
			terminal++
			metrics.DLQRetryAttemptsTotal.WithLabelValues("terminal").Inc()
		}
	}
	r.logger.Info("DLQ retry tick complete",
		slog.Int("examined", len(rows)),
		slog.Int("succeeded", succeeded),
		slog.Int("failed", failed),
		slog.Int("permanent", permanent),
		slog.Int("terminal", terminal),
		slog.Duration("elapsed", time.Since(start)))
	return nil
}

// retryOne re-replays a single DLQ row. Returns one of:
//
//	"succeeded" — replay returned nil; DLQ row deleted.
//	"failed"    — replay returned an error; retry_attempts++.
//	"permanent" — prod user_logs row no longer exists; DLQ row stays
//	              but bumped so the cap eventually retires it.
//	"terminal"  — edge-api PR #148 gate PERMANENTLY rejected the replay
//	              (409 STALE_HEAD/RANGE_CONFLICT/BEYOND_HORIZON); DLQ row
//	              retired to the cap immediately so it never re-drives.
//
// On any internal error (DB hiccup unrelated to the replay) we log and
// return "failed" so the row stays in the queue and gets retried next
// pass. We never panic the loop on a single bad row.
func (r *DLQRetrier) retryOne(ctx context.Context, row db.DLQRetryRow) string {
	prodLog, found, err := r.prod.FetchUserLogByID(ctx, row.SourceLogID, r.cfg.ProdEnterpriseID)
	if err != nil {
		r.logger.Warn("DLQ retry: prod user_log fetch failed — will retry next pass",
			slog.Int64("dlq_id", row.ID),
			slog.Int64("source_log_id", row.SourceLogID),
			slog.String("err", err.Error()))
		_ = r.staging.MarkDLQRetried(ctx, row.ID)
		return "failed"
	}
	if !found {
		// Prod row purged or never existed — no point retrying further.
		// Bump the counter so the row eventually retires past the cap
		// and stops showing up in the eligibility query.
		r.logger.Warn("DLQ retry: prod user_log no longer exists — bumping to retire",
			slog.Int64("dlq_id", row.ID),
			slog.Int64("source_log_id", row.SourceLogID))
		_ = r.staging.MarkDLQRetried(ctx, row.ID)
		return "permanent"
	}

	// Re-run the dispatcher inside a fresh staging tx. On success the
	// DLQ row goes away in the same tx — so the visible outcome is
	// atomic: either both replay and DLQ delete land, or neither does.
	replayErr := r.staging.WithTx(ctx, func(tx pgx.Tx) error {
		if dispErr := r.disp.Dispatch(ctx, tx, prodLog); dispErr != nil {
			return dispErr
		}
		return db.DeleteDLQRow(ctx, tx, row.ID)
	})
	if replayErr != nil {
		if errors.Is(replayErr, ErrTerminalReplay) {
			// edge-api PR #148 gate now returns a clean 409 for this
			// buffered PO-control action — it is PERMANENTLY stale. This is
			// exactly the row (e.g. the 2567207 stop) that churned every
			// tick under the old masked-500 regime. Retire it to the cap so
			// FetchRetriableDLQ never re-selects it; the row stays in the
			// tray for human review. Do NOT bump-by-one (that re-drives it
			// up to cap-1 more times for no reason).
			r.logger.Error("DLQ retry: replay permanently rejected by edge-api gate — retiring row (no further retries)",
				slog.Int64("dlq_id", row.ID),
				slog.Int64("source_log_id", row.SourceLogID),
				slog.String("category", row.Category),
				slog.Int("prior_attempts", row.RetryAttempts),
				slog.String("err", replayErr.Error()))
			_ = r.staging.RetireDLQRow(ctx, row.ID, r.cfg.DLQRetryMaxAttempts)
			return "terminal"
		}
		r.logger.Warn("DLQ retry failed — will retry after backoff",
			slog.Int64("dlq_id", row.ID),
			slog.Int64("source_log_id", row.SourceLogID),
			slog.String("category", row.Category),
			slog.Int("prior_attempts", row.RetryAttempts),
			slog.String("err", replayErr.Error()))
		_ = r.staging.MarkDLQRetried(ctx, row.ID)
		return "failed"
	}
	r.logger.Info("DLQ retry succeeded — row deleted",
		slog.Int64("dlq_id", row.ID),
		slog.Int64("source_log_id", row.SourceLogID),
		slog.String("category", row.Category),
		slog.Int("attempts_used", row.RetryAttempts+1))
	return "succeeded"
}
