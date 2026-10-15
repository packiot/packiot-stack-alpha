// batch.go — progress-safe batches for the bounded rollup passes (the shift pass
// and the hour backfill).
//
// THE FAILURE MODE (2026-10-14, staging). The runtime-rollup job runs hour → day →
// shift → week/month → entity → … under ONE 300 s tick deadline, each pass in its
// own transaction. When the shift pass is slower than the time left, the deadline
// cancels it mid-statement: its transaction rolls back (nothing committed, nothing
// drained) and every pass after it in that tick is cancelled too ("stale-flag
// week: context deadline exceeded", "area-day-flag: …"). The next tick picks the
// SAME batch (the rows are still flagged) and fails the same way: a fixed LIMIT
// that is too large for the current cost never makes progress, and it starves
// the grains downstream. From the 21:47 deploy every tick did exactly that, 15
// times in 3 h.
//
// THE FIX — two bounds:
//
//  1. A per-pass budget. The pass runs under its own deadline (shorter than the
//     tick's), so an over-budget pass is cancelled and rolled back ALONE — the
//     passes after it still run in the same tick.
//  2. An adaptive batch (batchSizer). A pass that ran out of budget halves the
//     next batch (down to a floor); a full batch that finished well inside the
//     budget doubles it back (up to the configured limit). Whatever the per-row
//     cost, the batch converges to a size that commits inside the budget, so a
//     backlog drains monotonically instead of rolling back forever.
//
// The per-row math is untouched: the batch only decides WHICH rows a tick
// recomputes (the eligible statements' LIMIT), never how.
package rollup

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"
)

// batchSizer is one adaptive LIMIT per destination. Safe for concurrent use.
type batchSizer struct {
	mu   sync.Mutex
	name string
	max  int
	min  int
	cur  map[string]int
}

// Default budgets. The runtime-rollup tick has 300 s (jobs.Loop: max(2×60 s, 5 min))
// for hour + day + shift + week/month + entity + dq + clamp + unmetered; the shift
// pass gets 120 s of it. The hour backfill runs alone in its job (also 300 s).
const (
	defaultShiftBudget    = 120 * time.Second
	defaultBackfillBudget = 120 * time.Second
)

// minBatch is the floor: small enough to fit any sane budget, large enough that
// the live tail (re-flagged every tick) still fits in a few ticks.
const minBatch = 5

func newBatchSizer(name string, max int) *batchSizer {
	if max < minBatch {
		max = minBatch
	}
	return &batchSizer{name: name, max: max, min: minBatch, cur: map[string]int{}}
}

// limit is the batch size the next tick for dest uses.
func (b *batchSizer) limit(dest string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	if n, ok := b.cur[dest]; ok {
		return n
	}
	return b.max
}

// observe adapts dest's batch to one finished tick: n rows processed with the
// given limit, elapsed wall time, and whether the pass ran out of its budget.
// It returns the new limit and whether it changed.
func (b *batchSizer) observe(dest string, limit int, n int64, elapsed, budget time.Duration, overBudget bool) (int, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	old, ok := b.cur[dest]
	if !ok {
		old = b.max
	}
	next := old
	switch {
	case overBudget:
		next = limit / 2
	case n >= int64(limit) && elapsed < budget/4:
		// a FULL batch finished in under a quarter of the budget → there is more
		// backlog and room for it.
		next = limit * 2
	}
	if next < b.min {
		next = b.min
	}
	if next > b.max {
		next = b.max
	}
	b.cur[dest] = next
	return next, next != old
}

// runBudgeted runs fn under its own deadline (the earlier of budget and the
// parent's) and reports whether it ran out of THAT budget — not the parent's —
// so the caller can shrink the next batch.
func runBudgeted(ctx context.Context, budget time.Duration, fn func(context.Context) (int64, error)) (n int64, elapsed time.Duration, overBudget bool, err error) {
	bctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	start := time.Now()
	n, err = fn(bctx)
	elapsed = time.Since(start)
	overBudget = err != nil && errors.Is(bctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil
	return n, elapsed, overBudget, err
}

// runAdaptive runs one bounded pass for dest with the sizer's current limit
// under budget, adapts the sizer and logs the change. It returns the limit it
// used, the pass's rows, whether the pass ran out of its own budget (nothing was
// committed; the next batch is halved) and the pass's error.
func runAdaptive(ctx context.Context, sz *batchSizer, dest string, budget time.Duration, logger *slog.Logger,
	pass func(ctx context.Context, limit int) (int64, error)) (limit int, n int64, overBudget bool, err error) {
	limit = sz.limit(dest)
	n, elapsed, overBudget, err := runBudgeted(ctx, budget, func(c context.Context) (int64, error) { return pass(c, limit) })
	if err == nil || overBudget {
		if next, changed := sz.observe(dest, limit, n, elapsed, budget, overBudget); changed && logger != nil {
			logger.Info(sz.name+" batch resized", slog.String("dest", dest), slog.Int("from", limit), slog.Int("to", next),
				slog.Bool("over_budget", overBudget), slog.Duration("elapsed", elapsed), slog.Duration("budget", budget))
		}
	}
	return limit, n, overBudget, err
}
