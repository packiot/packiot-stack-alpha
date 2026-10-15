// Package rollupshadow ticks the plain-PostgreSQL twins of the TimescaleDB continuous
// aggregates (ADR-0063 Phase B, db/migrations/t-ts-b1-rollup-shadow).
//
// The SQL owns the logic: silver.rollup_tick() recomputes the trailing live window and
// drains silver.rollup_invalidation (late, replayed or repaired rows). The engine only
// schedules it, because production's DB image has no pg_cron (go-live runbook D2) and,
// after the cutover, the rollup will refresh right before it reads.
//
// Shadow only: nothing reads the twins until the cutover migration renames them over the
// caggs. Off unless ROLLUP_SHADOW_ENABLED=true.
package rollupshadow

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// tickSQL selects the tick's counters. %s = the quoted silver schema.
const tickSQL = `SELECT live_rows, drained_minutes, drained_hours, remaining FROM %s.rollup_tick()`

// TickResult is one tick's outcome.
type TickResult struct {
	LiveRows       int64
	DrainedMinutes int32
	DrainedHours   int32
	Remaining      int32
}

// Query renders the tick statement for a schema (quoted: the schema comes from config).
func Query(silverSchema string) string {
	return fmt.Sprintf(tickSQL, pgx.Identifier{silverSchema}.Sanitize())
}

// RunTick runs one tick against a destination.
func RunTick(ctx context.Context, d flows.Dest) (TickResult, error) {
	var r TickResult
	err := d.Pool.QueryRow(ctx, Query(d.SilverSchema)).
		Scan(&r.LiveRows, &r.DrainedMinutes, &r.DrainedHours, &r.Remaining)
	if err != nil {
		return r, fmt.Errorf("rollup_tick: %w", err)
	}
	return r, nil
}

// Loop schedules the tick on the jobs runner (panic recovery, timeout, tick metrics).
func Loop(ctx context.Context, dests []flows.Dest, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("rollup shadow tick started (ADR-0063 Phase B, twins of the caggs)")
	jobs.Loop(ctx, jobs.Job{Name: "rollup-shadow", Every: every, Run: func(ctx context.Context) error {
		return jobs.RunPerDest(ctx, dests, "rollup-shadow", logger, func(ctx context.Context, d flows.Dest) (int64, error) {
			r, err := RunTick(ctx, d)
			if err != nil {
				return 0, err
			}
			if r.Remaining > 0 {
				// A backlog that survives ticks means the drain limit is too small for the
				// late-data rate — worth seeing, not an error.
				logger.Info("rollup shadow backlog", slog.String("dest", d.Name),
					slog.Int("drained_minutes", int(r.DrainedMinutes)), slog.Int("remaining", int(r.Remaining)))
			}
			return r.LiveRows, nil
		})
	}}, logger, obs)
}
