// closer.go — bounds/closes STALE OPEN equipment_events on the LIVE table for
// status_type=0 (CPACK-class) tenants. This is the recurring companion to the
// one-time backlog close in db/cutover/2026-08-24-close-stale-cpac-open-events.sql.
//
// ── WHY THIS EXISTS (the never-closed open-event bug) ────────────────────────
// CPACK (status_type=0) equipment events on the LIVE public.equipment_events
// are written by the mirror fan-out (FanoutEventRow) — a one-shot per-row upsert
// with NO closer. The status_type=4 deriver (deriver.go) skips them (wrong
// status_type). The CPAC count-silence deriver (cpac_deriver.go) that WOULD bound
// them writes only to the DARK shadow table (equipment_events_cpac_shadow) until
// its comparator gate flips. Net effect: CPACK open (ts_end IS NULL) rows are
// never closed. They accumulate (5.9k open status=6 on staging by 2026-08-24,
// oldest 08-13).
//
// The rollup (hour.go/shift.go) treats an open event as running to `now()`:
//   COALESCE(ee.ts_end, now())  and  tstzrange(ee.ts_event, COALESCE(ee.ts_end,
//   now())) && bucket. So ONE stale open status=6 makes every subsequent idle
// hour read running_time = full-hour → oee_a = 1.0 — fabricated ~100%
// availability on dead/idle lines (832 idle net=0 hours reading a>0.99 on
// staging), which then pass Grafana's running_time>0 guard and dilute the OEE
// headline far below the real producing-lines value.
//
// ── WHAT THIS JOB DOES (close only; never derive, never fabricate) ───────────
// For each in-scope open row it sets ts_end deterministically:
//   (a) NON-LATEST open → ts_end = lead(ts_event) over the equipment's stream:
//       an interval physically ends when the next transition begins. Pure
//       gaps-and-islands bounding; always correct regardless of who minted it.
//   (b) TRAILING open (no successor) → count-silence close at
//       greatest(ts_event, last_productive_minute + stop_threshold), applied
//       ONLY once that grace has elapsed (last count + thr < now — the machine
//       is genuinely silent). The greatest() clamp makes a phantom run with NO
//       supporting count collapse to zero duration (contributes no running
//       time); a real run that then went quiet settles at last-count+grace. A
//       still-live machine (last count + thr in the future) is LEFT OPEN.
//   Count activity + threshold are read EXACTLY as cpac_deriver.go infers them
//   (ca_agg_equipment_values_1min.gross_production_incr>0 ;
//   COALESCE(NULLIF(stop_threshold_time,0), default)) so the two share one model.
//
// ── INVARIANTS ───────────────────────────────────────────────────────────────
//   - Never clobbers a human edit: guarded by humanTouchedPred (shared with the
//     CPAC deriver) — justified/trimmed/reclassified operator rows are skipped,
//     so operator downtimes keep their ts_end/category intact.
//   - Idempotent: only ts_end IS NULL rows are ever written; a replay after the
//     backlog is drained touches nothing until fresh opens appear.
//   - Parity-safe: scoped to the configured status_type=0 enterprises and inert
//     on every ts_end-populated row, so it is a no-op on legacy/prod-derived
//     data and on any tenant not opted in.
package events

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// CloserConfig carries the flag-gated knobs for the stale-open closer. The zero
// value is inert: with no Enterprises the job closes nothing even when the
// caller (main.go) has already gated on Enabled.
type CloserConfig struct {
	Enterprises     []int // status_type=0 enterprise ids to close (CPACK=3); empty ⇒ no-op
	ThresholdDefSec int   // trailing-close grace when equipments.stop_threshold_time IS NULL/0
	HorizonHours    int   // only reconcile opens with ts_event >= now()-horizon (steady-state tail)
}

// humanJustifiedPred is the NULL-SAFE human-edit guard for the LIVE
// equipment_events table (aliased `ev` via %[4]s). It DELIBERATELY DIVERGES from
// cpac_deriver.go's humanTouchedPred in two ways, both forced by live-table
// reality (verified on staging F3, 2026-08-24):
//
//  1. It OMITS forced_creation_system. On the live table that column is TRUE for
//     EVERY mirror-fan-out system row (prod's normal derived-event flag) AND for
//     operator trims (30813/30814) — so it does NOT distinguish human from system
//     there. (On the shadow table cpac_deriver writes fcs=false, so there fcs=true
//     DOES mean human — hence humanTouchedPred keeps it.) A trim also stamps
//     ts_end, so a trimmed row is never open, and this closer only touches open
//     (ts_end IS NULL) rows; among opens the unambiguous human signal is a
//     justification/reclassification. Keeping fcs here would skip 100% of the
//     rows (every live system open is fcs=true) — closing nothing.
//  2. It is NULL-SAFE: planned_downtime/change_over are NULL (not false) on live
//     system rows, so a bare `OR ev.planned_downtime` yields NULL and NOT(NULL)
//     excludes the row — the closer would again touch nothing. `IS TRUE` / `IS
//     NOT NULL` collapse the three-valued logic so a plain system row passes.
const humanJustifiedPred = `(%[4]s.cd_category IS NOT NULL OR %[4]s.cd_subcategory IS NOT NULL
        OR %[4]s.cd_machine IS NOT NULL OR %[4]s.txt_downtime_notes IS NOT NULL
        OR %[4]s.planned_downtime IS TRUE OR %[4]s.change_over IS TRUE OR %[4]s.idle IS NOT NULL)`

// closeStaleOpensSQL bounds/closes in-scope open rows in ONE statement.
// %[1]s = EvSchema (flow tables), %[2]s = RefSchema (equipments), %[4]s = the
// humanJustifiedPred aliased to `ev` (index 3 is unused — kept so the alias
// lands at index 4, matching fmtCPAC). $1 = enterprise-id int[]; $2 = default
// threshold seconds; $3 = horizon hours.
const closeStaleOpensSQL = `
WITH scope AS (
    SELECT e.id_equipment,
           COALESCE(NULLIF(e.stop_threshold_time, 0), $2) AS thr
      FROM %[2]s.equipments e
     WHERE e.status_type = 0
       AND e.tp_equipment IN (1, 3)
       AND e.id_enterprise = ANY($1)
), lastcount AS (
    -- last productive minute per equipment within the horizon (count-activity
    -- silence is the CPACK availability signal — cpac_deriver.go rationale).
    SELECT s.id_equipment, s.thr, max(m.ts_value) AS last_ts
      FROM scope s
      JOIN %[1]s.ca_agg_equipment_values_1min m
        ON m.id_equipment = s.id_equipment
       AND m.ts_value > now() - make_interval(hours => $3)
       AND m.gross_production_incr > 0
     GROUP BY s.id_equipment, s.thr
), open_ev AS (
    SELECT ev.id_equipment_event, ev.id_equipment, ev.ts_event,
           lead(ev.ts_event) OVER (PARTITION BY ev.id_equipment
               ORDER BY ev.ts_event, ev.id_equipment_event) AS next_ts
      FROM %[1]s.equipment_events ev
      JOIN scope s ON s.id_equipment = ev.id_equipment
     WHERE ev.ts_event >= now() - make_interval(hours => $3)
), plan AS (
    SELECT o.id_equipment_event,
           CASE
             WHEN o.next_ts IS NOT NULL THEN o.next_ts
             ELSE greatest(o.ts_event, lc.last_ts + make_interval(secs => lc.thr))
           END AS new_end
      FROM open_ev o
      LEFT JOIN lastcount lc ON lc.id_equipment = o.id_equipment
     WHERE o.next_ts IS NOT NULL
        OR (lc.last_ts IS NOT NULL AND lc.last_ts + make_interval(secs => lc.thr) < now())
)
UPDATE %[1]s.equipment_events ev
   SET ts_end   = p.new_end,
       duration = extract(epoch FROM (p.new_end - ev.ts_event))::int,
       last_update = now()
  FROM plan p
 WHERE ev.id_equipment_event = p.id_equipment_event
   AND ev.ts_end IS NULL
   AND NOT ` + humanJustifiedPred

// defaultInt returns v when it is positive, else def — the inert-safe fallback
// for a zero-valued CloserConfig knob.
func defaultInt(v, def int) int {
	if v <= 0 {
		return def
	}
	return v
}

// RunOnceClose closes stale opens for one destination. Returns rows closed.
//
// COMPRESSED-CHUNK SAFETY (SQLSTATE 53400). equipment_events is a compressed
// hypertable; setting ts_end on an open row that lives in a compressed chunk
// forces TimescaleDB to decompress the affected segments. A CPACK tick can touch
// opens spread across dozens of chunks, blowing past the default
// max_tuples_decompressed_per_dml_transaction (100k) → the whole UPDATE aborts
// and NOT ONE stale open gets closed (observed on staging: every tick failing,
// 15k opens accumulated back to 2026-06-22). We therefore run the UPDATE in an
// explicit tx and lift the per-tx decompression cap to unlimited (0) for that tx
// only via SET LOCAL — the close is deterministic and bounded by the horizon, so
// unlimited decompression is safe and scoped. Mirrors the teardown-DAO fix for
// the same 53400 on telemetry deletes.
func RunOnceClose(ctx context.Context, d Dest, cfg CloserConfig) (int64, error) {
	thr := defaultInt(cfg.ThresholdDefSec, 300)
	horizon := defaultInt(cfg.HorizonHours, 72)
	// Positional args: %[1]s EvSchema, %[2]s RefSchema, %[3]s unused (kept so the
	// shared humanTouchedPred's %[4]s row-alias lands at index 4 — same contract
	// as fmtCPAC), %[4]s the aliased UPDATE-target row ("ev").
	sql := fmt.Sprintf(closeStaleOpensSQL, d.EvSchema, d.RefSchema, "", "ev")
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("close stale opens begin: %w", err)
	}
	defer tx.Rollback(ctx)
	// SET LOCAL: scoped to this tx, reverts on commit/rollback — never leaks to
	// the pooled connection. 0 = unlimited decompression for this DML.
	if _, err := tx.Exec(ctx, `SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0`); err != nil {
		return 0, fmt.Errorf("close stale opens set-local: %w", err)
	}
	tag, err := tx.Exec(ctx, sql, cfg.Enterprises, thr, horizon)
	if err != nil {
		return 0, fmt.Errorf("close stale opens: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("close stale opens commit: %w", err)
	}
	return tag.RowsAffected(), nil
}

// LoopClose runs the stale-open closer on a fixed cadence for every destination.
// Caller (main.go) gates on EVENTS_CLOSE_STALE_ENABLED before starting it.
func LoopClose(ctx context.Context, dests []Dest, cfg CloserConfig, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("stale-open events closer started (bounds live CPACK opens by next-event / count-silence)",
		slog.Int("destinations", len(dests)), slog.Int("enterprises", len(cfg.Enterprises)),
		slog.Int("threshold_default_sec", cfg.ThresholdDefSec), slog.Int("horizon_hours", cfg.HorizonHours))
	jobs.Loop(ctx, jobs.Job{Name: "events-close-stale", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			closed, err := RunOnceClose(ctx, d, cfg)
			if err != nil {
				logger.Warn("stale-open closer pass failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			if closed > 0 {
				logger.Info("stale-open events closed", slog.String("dest", d.Name), slog.Int64("closed", closed))
			}
		}
		return firstErr
	}}, logger, obs)
}
