package reports

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Shift06 ports prod's update_report_shift_enterprsie_06() procedure
// (Wave 2 port #2). The legacy orchestration is a rolling-window
// delete-and-reload: wipe the last 6 days (America/Montreal calendar)
// and re-insert from the get_report_shift_enterprsie_06() compute
// function, atomically. The compute function stays SQL for now (its
// deep port is ADR-0014 P4 follow-up); Go owns orchestration, cadence
// and observability — exactly the speed33 pattern.
//
// The 06b variant (21-day deep rebuild on its own cadence) is a named
// follow-up — this port covers the primary hot path verbatim.
const shift06Delete = `DELETE FROM customer_reports.shift
	WHERE customer_id = 6
	AND day >= (now() at time zone 'America/Montreal')::date - interval '6 day'`

const shift06Insert = `INSERT INTO customer_reports.shift
	(customer_id, line, shift, turno_hrs, day, job, shift_duration_h,
	 dt_duration_h, setup_duration_h, running, prss_qty, packed_qty,
	 shift_number, job_sequence, dt_plan_h, dt_unplan_h, shift_start_time)
	SELECT 6, line, shift, turno_hrs, day, job, shift_duration_h,
	 dt_duration_h, setup_duration_h, running, prss_qty, packed_qty,
	 shift_number, job_sequence, dt_plan_h, dt_unplan_h, shift_start_time
	FROM get_report_shift_enterprsie_06()`

// RunShift06 executes one atomic delete-and-reload pass.
func RunShift06(ctx context.Context, pool *pgxpool.Pool) (int64, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, shift06Delete); err != nil {
		return 0, err
	}
	ct, err := tx.Exec(ctx, shift06Insert)
	if err != nil {
		return 0, err
	}
	return ct.RowsAffected(), tx.Commit(ctx)
}

// LoopShift06 — staging-tuned cadence (prod's cron schedule is
// unreadable to awslambda; the COMPUTATION is verbatim, the cadence is
// the documented divergence, same class as the CAgg policies).
func LoopShift06(ctx context.Context, pool *pgxpool.Pool, every time.Duration, logger *slog.Logger) {
	t := time.NewTicker(every)
	defer t.Stop()
	logger.Info("shift06 report writer started (Wave 2 port #2)", slog.Duration("interval", every))
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			n, err := RunShift06(ctx, pool)
			if err != nil {
				logger.Warn("shift06 pass failed", slog.String("err", err.Error()))
				continue
			}
			if n > 0 {
				logger.Info("shift06 rows rebuilt", slog.Int64("rows", n))
			}
		}
	}
}
