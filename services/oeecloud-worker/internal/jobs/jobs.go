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

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

type Job struct {
	Name  string
	Every time.Duration
	Run   func(ctx context.Context) error
	// Timeout: 0 → max(2×Every, 5m). A hung tick must DIE, not
	// silently stop the ticker forever (prod runs a watchdog for
	// exactly this — terminate_long_proc_runtime; we build it in).
	Timeout time.Duration
}

// Observer receives one call per tick with outcome "ok" | "error" |
// "timeout" | "panic" — wired to the jobs_ticks_total CounterVec.
type Observer func(job, outcome string)

// Loop runs j on its cadence until ctx is done. Run panics are
// recovered, logged, and counted — never propagated.
func Loop(ctx context.Context, j Job, logger *slog.Logger, obs Observer) {
	t := time.NewTicker(j.Every)
	defer t.Stop()
	logger.Info("job started", slog.String("job", j.Name), slog.Duration("interval", j.Every))
	// FIRST TICK FIRES IMMEDIATELY. time.Ticker's first fire comes a
	// full interval in — for long-interval jobs under frequent deploys
	// that means NEVER (the hourly provision job silently starved for
	// a day of restarts; its failing dependency produced zero warns
	// because it produced zero executions). Every loop must run once
	// at boot or absence-of-logs is unreadable.
	if outcome := runOne(ctx, j, logger); obs != nil {
		obs(j.Name, outcome)
	}
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
	timeout := j.Timeout
	if timeout <= 0 {
		timeout = 2 * j.Every
		if timeout < 5*time.Minute {
			timeout = 5 * time.Minute
		}
	}
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	defer func() {
		if r := recover(); r != nil {
			outcome = "panic"
			logger.Error("job tick panicked (recovered)",
				slog.String("job", j.Name), slog.String("panic", fmt.Sprint(r)))
		}
	}()
	if err := j.Run(tctx); err != nil {
		if tctx.Err() != nil {
			logger.Error("job tick TIMED OUT (killed — terminate_long_proc_runtime lesson)",
				slog.String("job", j.Name), slog.Duration("timeout", timeout))
			return "timeout"
		}
		logger.Warn("job tick failed", slog.String("job", j.Name), slog.String("err", err.Error()))
		return "error"
	}
	return "ok"
}

// RunPerDest is the shared per-destination fan-out every multi-flow
// job repeats: run fn for each dest, log failures, return the first
// error (tick outcome), log row counts when positive.
func RunPerDest(ctx context.Context, dests []flows.Dest, name string, logger *slog.Logger,
	fn func(ctx context.Context, d flows.Dest) (int64, error)) error {
	var firstErr error
	for _, d := range dests {
		n, err := fn(ctx, d)
		if err != nil {
			logger.Warn(name+" pass failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if n > 0 {
			logger.Info(name+" rows", slog.String("dest", d.Name), slog.Int64("rows", n))
		}
	}
	return firstErr
}
