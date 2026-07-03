// Package jobs — the single ticker-loop implementation for the
// worker's scheduled jobs (report writers, events deriver, future
// UNS refreshers). Replaces three byte-similar loops that each lacked
// panic recovery: a poison tick in any job goroutine would have
// crashed the whole worker into a restart loop.
package jobs

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

type Job struct {
	Name  string
	Every time.Duration
	Run   func(ctx context.Context) error
}

// Observer receives one call per tick with outcome "ok" | "error" |
// "panic" — wired to the jobs_ticks_total CounterVec in main.
type Observer func(job, outcome string)

// Loop runs j on its cadence until ctx is done. Run panics are
// recovered, logged, and counted — never propagated.
func Loop(ctx context.Context, j Job, logger *slog.Logger, obs Observer) {
	t := time.NewTicker(j.Every)
	defer t.Stop()
	logger.Info("job started", slog.String("job", j.Name), slog.Duration("interval", j.Every))
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			outcome := runOne(ctx, j, logger)
			if obs != nil {
				obs(j.Name, outcome)
			}
		}
	}
}

func runOne(ctx context.Context, j Job, logger *slog.Logger) (outcome string) {
	defer func() {
		if r := recover(); r != nil {
			outcome = "panic"
			logger.Error("job tick panicked (recovered)",
				slog.String("job", j.Name), slog.String("panic", fmt.Sprint(r)))
		}
	}()
	if err := j.Run(ctx); err != nil {
		logger.Warn("job tick failed", slog.String("job", j.Name), slog.String("err", err.Error()))
		return "error"
	}
	return "ok"
}
