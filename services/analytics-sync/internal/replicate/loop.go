package replicate

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrSkip: payload is well-formed but not applicable — advance cursor, no
// failure. Mirrors the in-instance engine's ErrSkip contract.
var ErrSkip = errors.New("replicate: skip (not applicable)")

// Handler re-applies one legacy user_log onto staging. legacyPool is
// READ-ONLY (natural-key resolution); destPool receives every write;
// resolver translates ids at the boundary.
type Handler func(ctx context.Context, legacyPool, destPool *pgxpool.Pool, r *Resolver, u *UserLog) error

// Metrics is the counter surface (mirrors internal/replay.Metrics).
type Metrics interface {
	IncDispatched(category string)
	IncSkipped(category string)
	IncFailed(category string)
	SetCursor(id int64)
}

// Dispatcher routes a legacy user_log to the handler registered for its
// category. Unknown categories advance the cursor without failing.
type Dispatcher struct {
	handlers map[string]Handler
	logger   *slog.Logger
}

func NewDispatcher(logger *slog.Logger) *Dispatcher {
	return &Dispatcher{handlers: map[string]Handler{}, logger: logger}
}

func (d *Dispatcher) Register(category string, h Handler) { d.handlers[category] = h }

func (d *Dispatcher) Dispatch(ctx context.Context, legacyPool, destPool *pgxpool.Pool, r *Resolver, u *UserLog) (skipped bool, err error) {
	h, ok := d.handlers[u.Category]
	if !ok {
		return true, nil
	}
	err = h(ctx, legacyPool, destPool, r, u)
	if errors.Is(err, ErrSkip) {
		return true, nil
	}
	return false, err
}

// Loop drives poll -> dispatch -> advance-cursor. Runs until ctx cancelled.
func Loop(ctx context.Context, legacyPool, destPool *pgxpool.Pool, r *Resolver, d *Dispatcher, m Metrics, cfg *Config, logger *slog.Logger) error {
	cursor, err := EnsureCursor(ctx, destPool, legacyPool, cfg.CursorSource, cfg.SrcEnterprise, cfg.SinceStart(time.Now()))
	if err != nil {
		return err
	}
	logger.Info("replicate loop started",
		slog.Int64("cursor", cursor),
		slog.Int("src_enterprise", cfg.SrcEnterprise),
		slog.Int("dst_enterprise", cfg.DstEnterprise),
		slog.String("cursor_source", cfg.CursorSource))
	m.SetCursor(cursor)
	pollInterval := time.Duration(cfg.PollIntervalMs) * time.Millisecond

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		batch, err := FetchBatch(ctx, legacyPool, cfg.SrcEnterprise, cursor, cfg.BatchSize)
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
			skipped, err := d.Dispatch(ctx, legacyPool, destPool, r, u)
			switch {
			case err != nil:
				m.IncFailed(u.Category)
				logger.Warn("dispatch failed",
					slog.Int64("id_user_log", u.ID),
					slog.String("category", u.Category),
					slog.String("err", err.Error()))
				// Fail-open: advance past a poison row so the loop never wedges.
			case skipped:
				m.IncSkipped(u.Category)
			default:
				m.IncDispatched(u.Category)
			}
			cursor = u.ID
		}
		if err := AdvanceCursor(ctx, destPool, cfg.CursorSource, cursor); err != nil {
			logger.Warn("advance cursor failed", slog.Int64("cursor", cursor), slog.String("err", err.Error()))
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
