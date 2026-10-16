package reports

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// Shift06 ports prod's update_report_shift_enterprsie_06() procedure
// (Wave 2 port #2). The legacy orchestration is a rolling-window
// delete-and-reload: wipe the last 6 days (America/Montreal calendar)
// and re-insert from the compute function, atomically. The compute
// function stays SQL; Go owns orchestration, cadence and observability
// — exactly the speed33 pattern.
//
// t244 (enterprise-06/13 parameterization redesign, Phase 4): the read
// side now sources from the GENERIC serving.report_shift(p_id_enterprise,
// startdate, enddate) instead of the per-enterprise-cloned
// get_report_shift_enterprsie_06c(startdate, enddate). The enterprise is
// a REAL function argument ($1 = customerID) — no per-tenant function
// clone. serving.report_shift derives timezone/site-scope/area-exclusion
// from core.client_descriptors.descriptor->'reports' and returns the same
// 23-col contract. $1 was previously write-only (the pool customer_id);
// it is now also the read param.
//
// GENERATION NOTE (prod fidelity check, 2026-07-02): the plain-06
// orchestrator+compute is a DEAD generation — its SETOF rowtype drifted
// when the table gained 7 columns, and it now ERRORS on prod. The live
// chain was update_..._06b → get_..._06c (verified: 358 rows read-only
// on prod), now parameterized as serving.report_shift. This port
// implements the live semantics: 21-day Montreal wipe + 23-column reload.
// The dead-logger ping (piot_monitor_function) is deliberately dropped.
const shift06Delete = `DELETE FROM customer_reports.shift
	WHERE customer_id = $1
	AND day >= (now() at time zone 'America/Montreal')::date - interval '21 day'
	AND day <= (now() at time zone 'America/Montreal')::date`

const shift06Insert = `INSERT INTO customer_reports.shift
	(customer_id, line, shift, turno_hrs, day, job, shift_duration_h,
	 dt_duration_h, setup_duration_h, running, prss_qty, packed_qty,
	 shift_number, job_sequence, dt_plan_h, dt_unplan_h, shift_start_time,
	 index1, id_equipment, pro_h, res_h, mnt_h, discart_h, index2)
	SELECT $1::int, line, shift, turno_hrs, day, job, shift_duration_h,
	 dt_duration_h, setup_duration_h, running, prss_qty, packed_qty,
	 shift_number, job_sequence, dt_plan_h, dt_unplan_h, shift_start_time,
	 index1, id_equipment, pro_h, res_h, mnt_h, discart_h, index2
	FROM serving.report_shift($1,
	  ((now() at time zone 'America/Montreal')::date - interval '21 day')::date,
	  (now() at time zone 'America/Montreal')::date)`

// RunShift06 executes one atomic delete-and-reload pass.
func RunShift06(ctx context.Context, pool *pgxpool.Pool, customerID int) (int64, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, shift06Delete, customerID); err != nil {
		return 0, err
	}
	ct, err := tx.Exec(ctx, shift06Insert, customerID)
	if err != nil {
		return 0, err
	}
	return ct.RowsAffected(), tx.Commit(ctx)
}

// LoopShift06 — staging-tuned cadence (prod's cron schedule is
// unreadable to awslambda; the COMPUTATION is verbatim, the cadence is
// the documented divergence, same class as the CAgg policies).
func LoopShift06(ctx context.Context, pool *pgxpool.Pool, customerID int, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("shift06 report writer started (Wave 2 port #2)")
	jobs.Loop(ctx, jobs.Job{Name: "shift06", Every: every, Run: func(ctx context.Context) error {
		_, err := RunShift06(ctx, pool, customerID)
		return err
	}}, logger, obs)
}
