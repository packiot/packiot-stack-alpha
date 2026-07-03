package reports

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// Shift06 ports prod's update_report_shift_enterprsie_06() procedure
// (Wave 2 port #2). The legacy orchestration is a rolling-window
// delete-and-reload: wipe the last 6 days (America/Montreal calendar)
// and re-insert from the get_report_shift_enterprsie_06() compute
// function, atomically. The compute function stays SQL for now (its
// deep port is ADR-0014 P4 follow-up); Go owns orchestration, cadence
// and observability — exactly the speed33 pattern.
//
// GENERATION NOTE (prod fidelity check, 2026-07-02): the plain-06
// orchestrator+compute is a DEAD generation — its SETOF rowtype drifted
// when the table gained 7 columns, and it now ERRORS on prod. The live
// chain is update_..._06b → get_..._06c (verified: 358 rows read-only
// on prod). This port implements the live semantics: 21-day Montreal
// wipe + 23-column reload from 06c. The dead-logger ping
// (piot_monitor_function) is deliberately dropped.
const shift06Delete = `DELETE FROM customer_reports.shift
	WHERE customer_id = 6
	AND day >= (now() at time zone 'America/Montreal')::date - interval '21 day'
	AND day <= (now() at time zone 'America/Montreal')::date`

const shift06Insert = `INSERT INTO customer_reports.shift
	(customer_id, line, shift, turno_hrs, day, job, shift_duration_h,
	 dt_duration_h, setup_duration_h, running, prss_qty, packed_qty,
	 shift_number, job_sequence, dt_plan_h, dt_unplan_h, shift_start_time,
	 index1, id_equipment, pro_h, res_h, mnt_h, discart_h, index2)
	SELECT 6, line, shift, turno_hrs, day, job, shift_duration_h,
	 dt_duration_h, setup_duration_h, running, prss_qty, packed_qty,
	 shift_number, job_sequence, dt_plan_h, dt_unplan_h, shift_start_time,
	 index1, id_equipment, pro_h, res_h, mnt_h, discart_h, index2
	FROM get_report_shift_enterprsie_06c(
	  ((now() at time zone 'America/Montreal')::date - interval '21 day')::date,
	  (now() at time zone 'America/Montreal')::date)`

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
func LoopShift06(ctx context.Context, pool *pgxpool.Pool, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("shift06 report writer started (Wave 2 port #2)")
	jobs.Loop(ctx, jobs.Job{Name: "shift06", Every: every, Run: func(ctx context.Context) error {
		_, err := RunShift06(ctx, pool)
		return err
	}}, logger, obs)
}
