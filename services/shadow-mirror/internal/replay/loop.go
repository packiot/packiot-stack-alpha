package replay

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Metrics is the callback surface for /metrics counters. Kept as an
// interface so tests + main can pass tiny mocks; production wires the
// prometheus counters directly.
type Metrics interface {
	IncDispatched(category string)
	IncSkipped(category string)
	IncFailed(category string)
	SetCursor(id int64)
}

// Loop is the polling driver: fetch a batch, dispatch, advance cursor,
// sleep. Runs until ctx is cancelled.
func Loop(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, dispatcher *Dispatcher, m Metrics, pollInterval time.Duration, batchSize int, logger *slog.Logger) error {
	cursor, err := EnsureCursor(ctx, mainPool)
	if err != nil {
		return err
	}
	logger.Info("shadow-mirror loop started",
		slog.Int64("cursor", cursor),
		slog.Duration("poll_interval", pollInterval),
		slog.Int("batch_size", batchSize),
	)
	m.SetCursor(cursor)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		batch, err := FetchBatch(ctx, mainPool, cursor, batchSize)
		if err != nil {
			logger.Warn("fetch batch failed", slog.String("err", err.Error()))
			sleepCtx(ctx, pollInterval)
			continue
		}
		if len(batch) == 0 {
			sleepCtx(ctx, pollInterval)
			continue
		}

		for i := range batch {
			u := &batch[i]
			skipped, err := dispatcher.Dispatch(ctx, mainPool, shadowPool, u)
			switch {
			case err != nil:
				m.IncFailed(u.Category)
				logger.Warn("dispatch failed",
					slog.Int64("id_user_log", u.ID),
					slog.String("category", u.Category),
					slog.String("err", err.Error()))
				// v1: fail-open — advance cursor even on error so a
				// bad row doesn't jam the loop. v2 will add proper
				// DLQ + retry, matching mirror-worker's pattern.
			case skipped:
				m.IncSkipped(u.Category)
			default:
				m.IncDispatched(u.Category)
			}
			cursor = u.ID
		}

		if err := AdvanceCursor(ctx, mainPool, cursor); err != nil {
			logger.Warn("advance cursor failed",
				slog.Int64("cursor", cursor),
				slog.String("err", err.Error()))
			// Non-fatal — the next iteration will re-fetch from the
			// same cursor position (idempotent since handlers use
			// ON CONFLICT semantics).
		}
		m.SetCursor(cursor)
	}
}

func sleepCtx(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
