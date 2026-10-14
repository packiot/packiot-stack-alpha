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
//   (equipment_categorical_1min.gross_production_incr>0 ;
//   COALESCE(NULLIF(stop_threshold_time,0), default)) so the two share one model.
//
// ── INVARIANTS ───────────────────────────────────────────────────────────────
//   - Never clobbers a human edit: the human-justified guard (humanJustifiedPred)
//     protects ONLY the trailing count-silence close — where auto-closing an
//     operator's genuinely-ongoing downtime would overwrite intent. A NON-LATEST
//     open (a successor transition exists) is closed at next_ts UNCONDITIONALLY:
//     the interval provably ended when the next event began, and filling the
//     missing ts_end never touches the category. This is required for CPACK mirror
//     rows, which carry the source's category/notes but no ts_end — the guard
//     would otherwise mistake source categories for staging-table operator edits
//     and leave them open forever, blanketing availability (the ent-3 line-OEE bug).
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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// CloserConfig carries the flag-gated knobs for the stale-open closer. The zero
// value is inert: with no Enterprises the job closes nothing even when the
// caller (main.go) has already gated on Enabled.
type CloserConfig struct {
	Enterprises     []int // status_type=0 enterprise ids to close (CPACK=3); empty ⇒ no-op
	ThresholdDefSec int   // trailing-close grace when equipments.stop_threshold_time IS NULL/0
	HorizonHours    int   // only reconcile opens with ts_event >= now()-horizon (steady-state tail)
	LongHorizonDays int   // long-open pass: open rows older than the horizon, within this many days
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

// The main pass is three pieces: the scope, the last productive minute per
// equipment (read from the real-time categorical cagg), and the plan + UPDATE.
//
// READ/APPLY SPLIT (ADR-0063 Phase A2, 2026-10-14). TimescaleDB constifies a
// real-time cagg's watermark only when it plans a SELECT. Inside an UPDATE,
// cagg_watermark() stays a runtime call, so the planner priced the cagg's raw
// tail at every equipment_values chunk (staging plan: 458 M rows, total cost
// 2.4e8) and then merge-joined the plan against EVERY equipment_events chunk
// (3.16 M rows). The statement averaged 19.8 s (25 s as stream_engine) and was
// the largest single consumer of DB time (461,216 s, 15 % since 09-24) — the
// same trap #1770 fixed in cpac_deriver.go. RunOnceClose now reads lastcount in
// a plain SELECT (closeReadSQL, constified watermark, total cost ~2.2e4) and
// hands it to the UPDATE as jsonb (closeApplySQL), in the same transaction, so
// both see one now(). The UPDATE target is also bounded by the horizon start as
// a literal: plan rows have ts_event >= now() - horizon and the match is
// ts_event equality, so the bound changes nothing but lets the planner exclude
// every older chunk. closeStaleOpensSQL (the single-statement form) is kept as
// the reference the golden test compares against.
//
// Format args: %[1]s = EvSchema (flow tables), %[2]s = RefSchema (equipments),
// %[4]s = the humanJustifiedPred alias `ev` (index 3 unused — kept so the alias
// lands at index 4, matching fmtCPAC), %[5]s = an extra predicate on the UPDATE
// target ("" or closeTargetBound). $1 = enterprise-id int[]; $2 = default
// threshold seconds; $3 = horizon hours; apply only: $4 = lastcount snapshot
// (jsonb), $5 = horizon start (timestamptz).
const closeScopeCTE = `
WITH scope AS (
    SELECT e.id_equipment,
           COALESCE(NULLIF(e.stop_threshold_time, 0), $2) AS thr
      FROM %[2]s.equipments e
     WHERE e.status_type = 0
       AND e.tp_equipment IN (1, 3)
       AND e.id_enterprise = ANY($1)
)`

// closeLastCountCTE reads the real-time cagg. Only ever planned as a SELECT
// (closeReadSQL) on the live path.
const closeLastCountCTE = `, lastcount AS (
    -- last productive minute per equipment within the horizon (count-activity
    -- silence is the CPACK availability signal — cpac_deriver.go rationale).
    SELECT s.id_equipment, s.thr, max(m.ts_value) AS last_ts
      FROM scope s
      JOIN %[1]s.equipment_categorical_1min m
        ON m.id_equipment = s.id_equipment
       AND m.ts_value > now() - make_interval(hours => $3)
       AND m.gross_production_incr > 0
     GROUP BY s.id_equipment, s.thr
)`

// closeSnapshotLastCountCTE is closeLastCountCTE's rows, as read by closeReadSQL
// earlier in the same transaction (thr still comes from scope).
const closeSnapshotLastCountCTE = `, lastcount AS (
    SELECT s.id_equipment, s.thr, x.last_ts
      FROM scope s
      JOIN jsonb_to_recordset($4::jsonb) AS x(id_equipment int, last_ts timestamptz)
        ON x.id_equipment = s.id_equipment
)`

// closeTargetBound limits the UPDATE target to the horizon (see above).
const closeTargetBound = `
   AND ev.ts_event >= $5::timestamptz`

// closePlanUpdateSQL is the rest of the main pass: open rows, the plan, the UPDATE.
const closePlanUpdateSQL = `, open_ev AS (
    SELECT ev.id_equipment_event, ev.id_equipment, ev.ts_event, ev.status,
           lead(ev.ts_event) OVER (PARTITION BY ev.id_equipment
               ORDER BY ev.ts_event, ev.id_equipment_event) AS next_ts
      FROM %[1]s.equipment_events ev
      JOIN scope s ON s.id_equipment = ev.id_equipment
     WHERE ev.ts_event >= now() - make_interval(hours => $3)
), plan AS (
    SELECT o.id_equipment_event, o.id_equipment, o.ts_event,
           CASE
             WHEN o.next_ts IS NOT NULL THEN o.next_ts
             ELSE greatest(o.ts_event, lc.last_ts + make_interval(secs => lc.thr))
           END AS new_end,
           -- NON-LATEST (a successor transition exists) ⇒ the interval PROVABLY
           -- ended when the next event began. This bound is pure physics, not a
           -- judgment call, so it is applied UNCONDITIONALLY — even to a
           -- source-categorized row. (CPACK mirror rows carry the source's
           -- category/notes but never a ts_end; the human-edit guard below would
           -- otherwise mistake that for a staging-table operator edit and leave
           -- them open forever, blanketing availability — the ent-3 line-OEE bug.)
           (o.next_ts IS NOT NULL) AS bounded_by_next
      FROM open_ev o
      LEFT JOIN lastcount lc ON lc.id_equipment = o.id_equipment
     WHERE o.next_ts IS NOT NULL
        -- TRAILING count-silence close is for RUNNING rows ONLY (status 6): an open run
        -- stretched to now() fabricates availability. An open STOP is ongoing downtime —
        -- the truth — and its last count PRECEDES it, so greatest(ts_event, last+thr)
        -- ended it at (or ≤thr after) its own start. Because only ts_end IS NULL rows are
        -- ever touched, that truncation was PERMANENT even after the machine restarted:
        -- measured 2026-09-24, CPACK 955/3791 stops truncated (1,328 downtime-hours in 7 d)
        -- + 253 zero-length. Open stops now stay open until the next transition bounds
        -- them (the next_ts branch above).
        OR (o.status = 6 AND lc.last_ts IS NOT NULL AND lc.last_ts + make_interval(secs => lc.thr) < now())
)
UPDATE %[1]s.equipment_events ev
   SET ts_end   = p.new_end,
       duration = extract(epoch FROM (p.new_end - ev.ts_event))::int,
       last_update = now()
  FROM plan p
 -- True PK (id_equipment, ts_event): id_equipment_event is NOT unique (the
 -- sandbox twin reuses CPACK's ids), so matching on it could write one
 -- tenant's end onto another tenant's row.
 WHERE ev.id_equipment = p.id_equipment AND ev.ts_event = p.ts_event%[5]s
   AND (ev.ts_end IS NULL
        -- REBIND (2026-09-28): once a successor exists, the interval ends at the
        -- successor's start (legacy semantics) even if the row was already
        -- closed. The count-silence close runs before late or out-of-order
        -- events arrive, so it could end a row at its own start (zero-length
        -- when the row arrived late) or past its successor (overlap), and the
        -- IS NULL guard made that permanent. Audit: ~350 h of CPACK downtime
        -- lost in 14 days.
        OR (p.bounded_by_next AND ev.ts_end IS DISTINCT FROM p.new_end))
   -- Human-edit guard applies ONLY to the TRAILING close (count-silence), where
   -- auto-closing an operator's genuinely-ongoing downtime would clobber intent.
   -- A next-event-bounded close never destroys the category — it only fills the
   -- missing ts_end at the physically-correct boundary — so it bypasses the guard.
   AND (p.bounded_by_next OR NOT ` + humanJustifiedPred + `)`

// closeStaleOpensSQL is the single-statement main pass (cagg read inside the
// UPDATE). Not used on the live path; the golden test pins the read/apply split
// against it. Format with %[5]s = "".
const closeStaleOpensSQL = closeScopeCTE + closeLastCountCTE + closePlanUpdateSQL

// closeReadSQL returns the lastcount snapshot (jsonb text; jsonb keeps µs
// timestamps exact) and the horizon start, both from this transaction's now().
const closeReadSQL = closeScopeCTE + closeLastCountCTE + `
SELECT (SELECT COALESCE(jsonb_agg(jsonb_build_object('id_equipment', id_equipment, 'last_ts', last_ts)), '[]'::jsonb)::text
          FROM lastcount) AS lastcount,
       (now() - make_interval(hours => $3))::text AS horizon_start`

// closeApplySQL is closeStaleOpensSQL with lastcount read from the snapshot and
// the target bounded by the horizon start.
const closeApplySQL = closeScopeCTE + closeSnapshotLastCountCTE + closePlanUpdateSQL

// closeLongOpensSQL — the LONG-OPEN pass. closeStaleOpensSQL only sees events with
// ts_event >= now()-horizon (72 h) and computes lead() inside that window, so an open
// STOP that outlives the horizon falls out of scope: when its successor arrives days
// later the stop is never bounded. Measured 2026-09-24: CPACK orphans of 4–52 days
// (oldest 2024-06-03) shown as open-ended stops in every Events-tab window.
// This pass takes ONLY open rows older than the horizon (few) within LongHorizonDays and
// finds each one's successor with a PK-ordered LIMIT 1 lookup (no window over all
// events), closing it at the successor's ts_event — the same unconditional
// "bounded-by-next" rule as the main pass (a successor provably ends the interval;
// category/notes untouched). Rows without a successor stay open. Updates by the true
// PK (id_equipment, ts_event): id_equipment_event is not unique.
// %[1]s EvSchema, %[2]s RefSchema. $1 enterprises, $2 horizon hours, $3 long-horizon days.
const closeLongOpensSQL = `
WITH scope AS (
    SELECT e.id_equipment
      FROM %[2]s.equipments e
     WHERE e.status_type = 0
       AND e.tp_equipment IN (1, 3)
       AND e.id_enterprise = ANY($1)
), lo AS (
    SELECT ev.id_equipment, ev.ts_event, nx.ts_event AS next_ts
      FROM %[1]s.equipment_events ev
      JOIN scope s ON s.id_equipment = ev.id_equipment
     CROSS JOIN LATERAL (
           SELECT n.ts_event FROM %[1]s.equipment_events n
            WHERE n.id_equipment = ev.id_equipment AND n.ts_event > ev.ts_event
            ORDER BY n.ts_event LIMIT 1) nx
     WHERE ev.ts_end IS NULL
       AND ev.ts_event <  now() - make_interval(hours => $2)
       AND ev.ts_event >= now() - make_interval(days => $3)
)
UPDATE %[1]s.equipment_events ev
   SET ts_end      = lo.next_ts,
       duration    = extract(epoch FROM (lo.next_ts - ev.ts_event))::int,
       last_update = now()
  FROM lo
 WHERE ev.id_equipment = lo.id_equipment AND ev.ts_event = lo.ts_event
   AND ev.ts_end IS NULL`

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
	tag, err := runCloseMain(ctx, tx, d, cfg.Enterprises, thr, horizon)
	if err != nil {
		return 0, err
	}
	longTag, err := tx.Exec(ctx, fmt.Sprintf(closeLongOpensSQL, d.SilverSchema, d.RefSchema),
		cfg.Enterprises, horizon, defaultInt(cfg.LongHorizonDays, 60))
	if err != nil {
		return 0, fmt.Errorf("close long opens: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("close stale opens commit: %w", err)
	}
	return tag.RowsAffected() + longTag.RowsAffected(), nil
}

// runCloseMain runs the main pass inside tx: closeReadSQL (a plain SELECT, so
// the cagg's watermark is constified), then closeApplySQL with that snapshot.
func runCloseMain(ctx context.Context, tx pgx.Tx, d Dest, enterprises []int, thr, horizon int) (pgconn.CommandTag, error) {
	var snap, lo string
	if err := tx.QueryRow(ctx, fmt.Sprintf(closeReadSQL, d.SilverSchema, d.RefSchema, "", "ev", ""),
		enterprises, thr, horizon).Scan(&snap, &lo); err != nil {
		return pgconn.CommandTag{}, fmt.Errorf("close stale opens read: %w", err)
	}
	tag, err := tx.Exec(ctx, fmt.Sprintf(closeApplySQL, d.SilverSchema, d.RefSchema, "", "ev", closeTargetBound),
		enterprises, thr, horizon, snap, lo)
	if err != nil {
		return pgconn.CommandTag{}, fmt.Errorf("close stale opens: %w", err)
	}
	return tag, nil
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
