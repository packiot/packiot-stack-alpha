// cpac_deriver.go — ADR-0010 §10.4 GAP-1: the CPAC (status_type=0) stop
// derivation that the Go stack was missing. Built DARK (flag-gated,
// CPAC_EVENT_DERIVATION_ENABLED, default OFF). Deploying it is behavior-
// identical until the flag flips: it is a WHOLE NEW job that writes a WHOLE
// NEW table (the shadow comparison table, default equipment_events_cpac_shadow),
// so the flag-off executed-statement stream is byte-unchanged and the
// status_type=4 deriver (deriver.go) is completely untouched — this is a
// PARALLEL path, not a widening of the 4-only gates.
//
// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
// C-PACK equipment is status_type=0. On prod its downtime events are created
// by the factory CPAC algorithm (SparkPlug 30758=4) and reach staging via the
// mirror-worker FanoutEventRow. The Go stack itself has NO stop-detector for
// status_type=0 — the deriver.go path SERVES status_type=4 ONLY (it islands on
// state-VALUE transitions in ca_discrete_changes_1s). Flipping CPACK 0→4 is
// UNSAFE: the Go Calc engine emits a RUNNING-ONLY heartbeat (calc.go Phase 10
// only ever sets status=6; it never emits a stopped value), so islanding on
// state values yields zero stops. This job ADDS the missing detector, scoped
// to status_type=0, leaving status_type alone.
//
// ── INPUT: COUNT-ACTIVITY SILENCE, NOT STATE (empirical, 2026-08-04) ─────────
// STEP-1 sampling of live staging CPACK (enterprise 3):
//   - public.equipment_values.state is 100% NULL for the LIVE edge path (the
//     agent → edge-transformer path writes counts only; the Calc status=6
//     heartbeat never lands as a `state` value). State values (6/10) exist in
//     equipment_values ONLY in the mirror-fed shadow flow (FanoutStateRow),
//     which is prod's OWN derived state — islanding over it would be circular
//     (re-deriving prod's output) and evaporates the day the prod cord is cut.
//   - The ONE independent live signal is the COUNT stream (gross_production_incr
//     > 0), cadence p50 ~60s / p95 ~90–460s per equipment.
// So the CPAC "heartbeat" here is a PRODUCTIVE MINUTE. Silence longer than the
// equipment's stop threshold ⇒ a STOPPED interval. This is the same idle-timeout
// sessionization the counters-only availability fallback already uses
// (rollup/availability.go), lifted up to MINT equipment_events instead of
// computing running_time — so the two OEE paths share one inference model.
//
// ── THRESHOLD ───────────────────────────────────────────────────────────────
// Per-equipment horizon = equipments.stop_threshold_time (legacy SparkPlug
// Parameter 30751 "min-threshold-time"; the same column sap13_body.sql uses to
// split real stops (≥ threshold) from microstops (< threshold)). On staging
// this column is NULL for all 62 CPACK rows, so the derivation falls back to
// CPAC_STOP_THRESHOLD_DEFAULT_SEC. The default IS the tuning knob the comparator
// gates: too tight (e.g. 300s) over-detects — normal count-cadence gaps read as
// stops (dry-run: 181 derived stops vs prod's 64 in a 25h window). Enablement is
// gated on the comparator (cpac_deriver_comparator.sql) reaching acceptable
// convergence, at which point per-equipment stop_threshold_time should be
// populated rather than leaning on the single default.
//
// ── EVENT SHAPE ─────────────────────────────────────────────────────────────
// A "session" = a maximal run of productive minutes whose inter-minute gap never
// exceeds the threshold. RUNNING (status 6) transition at the session's first
// count; STOPPED (status 10) transition at (session's last count + threshold) —
// the grace we grant before declaring the machine down (identical to
// availability.go's session credit). The transitions are then chained
// (lead(ts_event) → ts_end, duration = epoch diff; open tail row → ts_end NULL,
// duration to now()), reproducing prod's alternating 6/10 interval stream. This
// matches prod's stream SHAPE; exact ts_end boundaries diverge within the
// documented convergence tolerance (count-silence cannot see sub-cadence stops
// the PLC state signal catches — that is the known limitation the comparator
// quantifies). status 6/10 are prod's literal codes (mirrored ground truth).
//
// ── IDEMPOTENT + NEVER CLOBBER A HUMAN EDIT (the load-bearing invariant) ─────
// The detector AUTO-INSERTS events that operators later MODIFY (justify a
// reason, adjust ts, split) via edge-api → pocontrol events_justify.go (30810
// justify sets cd_category/txt_downtime_notes/…; 30813/30814 trims set
// forced_creation_system=true). Re-derivation MUST:
//   - be idempotent: the upsert keys on (id_equipment, ts_event) and re-writes
//     identical values, so a replay of the same minutes changes nothing;
//   - never overwrite a human-touched row: the ON CONFLICT DO UPDATE carries a
//     WHERE that excludes any row a human has touched (humanTouchedPred);
//   - never delete a human-touched row: the correct/delete pass carries the same
//     guard (so the classic forced_creation_system guard is STRICTLY widened,
//     never narrowed);
//   - append ONLY in un-covered time: a freshly derived transition whose
//     ts_event falls inside a human-protected event's [ts_event, ts_end] span is
//     dropped from the upsert (NOT EXISTS humancover), AND any non-human derived
//     row minted BEFORE the human took the region is swept by the correct pass —
//     so a split/edited region ends up owned entirely by the operator, never
//     re-minted over and never left double-covered.
package events

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// CPACConfig carries the flag-gated knobs for the CPAC stop derivation. The
// zero value is inert: with no Enterprises the job mints nothing even when the
// caller (main.go) has already gated on Enabled.
type CPACConfig struct {
	Enterprises     []int  // status_type=0 enterprise ids to derive (CPACK=3); empty ⇒ no-op
	ThresholdDefSec int    // fallback when equipments.stop_threshold_time IS NULL/0
	TargetTable     string // shadow comparison table in EvSchema; default equipment_events_cpac_shadow
}

// DefaultCPACTargetTable is the DARK-mode shadow table the derivation writes to
// so the live equipment_events (owned by the mirror fan-out for CPACK, and by
// operators) is never touched and the comparator has a clean two-table diff.
const DefaultCPACTargetTable = "equipment_events_cpac_shadow"

// humanTouchedPred is the SQL predicate (over an aliased equipment_events row
// `%[4]s`) that is TRUE once an operator has touched the row via edge-api
// (pocontrol events_justify.go). Any one of: a trim/manual system-lock
// (forced_creation_system), a justification (cd_category / cd_subcategory /
// cd_machine / txt_downtime_notes), or a classification toggle
// (planned_downtime / change_over / idle). Referenced by BOTH the upsert guard
// and the delete guard so the detector can only ADD in untouched time.
const humanTouchedPred = `(%[4]s.forced_creation_system
        OR %[4]s.cd_category IS NOT NULL OR %[4]s.cd_subcategory IS NOT NULL
        OR %[4]s.cd_machine IS NOT NULL OR %[4]s.txt_downtime_notes IS NOT NULL
        OR %[4]s.planned_downtime OR %[4]s.change_over OR %[4]s.idle IS NOT NULL)`

// cpacTransitionsCTE recomputes the alternating running/stopped transition
// stream from count-activity sessionization over the last 25 hours.
// %[1]s = EvSchema (flow tables), %[2]s = RefSchema (equipments/packml).
// $1 = enterprise-id int[] scope, $2 = default threshold seconds.
const cpacTransitionsCTE = `
WITH scope AS (
    SELECT e.id_equipment, e.id_enterprise,
           COALESCE(NULLIF(e.stop_threshold_time, 0), $2) AS thr
      FROM %[2]s.equipments e
     WHERE e.status_type = 0
       AND e.tp_equipment IN (1, 3)
       AND e.id_enterprise = ANY($1)
), counts AS (
    SELECT s.id_equipment, s.id_enterprise, s.thr, m.ts_value AS ts,
           extract(epoch FROM (m.ts_value - lag(m.ts_value)
               OVER (PARTITION BY s.id_equipment ORDER BY m.ts_value))) AS gap
      FROM scope s
      JOIN %[1]s.ca_agg_equipment_values_1min m
        ON m.id_equipment = s.id_equipment
       AND m.ts_value > now() - interval '25 hours'
       AND m.gross_production_incr > 0
), marked AS (
    SELECT id_equipment, id_enterprise, thr, ts,
           sum(CASE WHEN gap IS NULL OR gap > thr THEN 1 ELSE 0 END)
               OVER (PARTITION BY id_equipment ORDER BY ts) AS sess
      FROM counts
), sessions AS (
    SELECT id_equipment, id_enterprise, thr, sess,
           min(ts) AS run_start, max(ts) AS run_last
      FROM marked
     GROUP BY id_equipment, id_enterprise, thr, sess
), transitions AS (
    -- RUNNING transition at the session's first productive minute
    SELECT id_equipment, id_enterprise, run_start AS ts_event, 6 AS status
      FROM sessions
    UNION ALL
    -- STOPPED transition at (last productive minute + grace threshold); only
    -- once the grace has actually elapsed (a stop has genuinely begun)
    SELECT id_equipment, id_enterprise,
           run_last + make_interval(secs => thr) AS ts_event, 10 AS status
      FROM sessions
     WHERE run_last + make_interval(secs => thr) < now()
), final AS (
    SELECT ts_event,
           lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event) AS ts_end,
           id_equipment, status, id_enterprise,
           extract(epoch FROM (coalesce(
               lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event),
               now()) - ts_event)) AS duration
      FROM transitions
     -- warmup: skip the window's first 10s (matches deriver.go's time guard on
     -- sparse streams; a row-count warmup is wrong here too)
     WHERE ts_event >= now() - interval '25 hours' + interval '10 seconds'
)`

// cpacUpsertSQL mints/refreshes the derived transitions into the shadow table.
// %[3]s = target table (aliased `ev` = %[4]s below). IDEMPOTENT on
// (id_equipment, ts_event). The DO UPDATE WHERE and the NOT EXISTS both enforce
// the never-clobber-a-human-edit invariant.
const cpacUpsertSQL = cpacTransitionsCTE + `
INSERT INTO %[1]s.%[3]s AS ev
       (ts_event, ts_end, id_equipment, status, id_enterprise, duration, forced_creation_system)
SELECT f.ts_event, f.ts_end, f.id_equipment, f.status, f.id_enterprise, f.duration, false
  FROM final f
 -- append ONLY in un-covered time: never re-mint over a human-protected span
 WHERE NOT EXISTS (
        SELECT 1 FROM %[1]s.%[3]s h
         WHERE h.id_equipment = f.id_equipment
           AND ` + humanCoverPred + `
           AND f.ts_event >= h.ts_event
           AND f.ts_event < COALESCE(h.ts_end, now()))
ON CONFLICT (id_equipment, ts_event) DO UPDATE
   SET ts_end = EXCLUDED.ts_end, status = EXCLUDED.status, duration = EXCLUDED.duration
 WHERE NOT ` + humanTouchedPred

// humanCoverPred (aliased `h` = %[4]s at format time) — a human-protected event
// used by the append-only NOT EXISTS. Same touched-columns as humanTouchedPred.
const humanCoverPred = `(h.forced_creation_system
        OR h.cd_category IS NOT NULL OR h.cd_subcategory IS NOT NULL
        OR h.cd_machine IS NOT NULL OR h.txt_downtime_notes IS NOT NULL
        OR h.planned_downtime OR h.change_over OR h.idle IS NOT NULL)`

// cpacCorrectSQL removes stale DERIVED rows (last 1 day) that the recomputed
// stream no longer supports — but NEVER a human-touched row (the guard is a
// STRICT widening of deriver.go's forced_creation_system-only guard).
const cpacCorrectSQL = cpacTransitionsCTE + `
DELETE FROM %[1]s.%[3]s ev
 WHERE ev.ts_event > now() - interval '1 day'
   AND ev.id_enterprise = ANY($1)
   AND NOT ` + humanTouchedPred + `
   AND (
     -- (a) stale: the recomputed stream no longer supports this derived row
     NOT EXISTS (SELECT 1 FROM final t
        WHERE t.id_equipment = ev.id_equipment
          AND t.ts_event = ev.ts_event AND t.status = ev.status)
     -- (b) superseded: a human later took ownership of a span this derived row
     -- falls inside (a manual-create/split at a different ts_event). Removing a
     -- NON-human row that a human span now covers is not clobbering an edit — it
     -- yields the region to the operator's version, completing "append only in
     -- un-covered time" for rows minted before the human touched the region.
     OR EXISTS (SELECT 1 FROM %[1]s.%[3]s h
        WHERE h.id_equipment = ev.id_equipment
          AND h.ts_event <> ev.ts_event
          AND ` + humanCoverPred + `
          AND ev.ts_event >= h.ts_event
          AND ev.ts_event < COALESCE(h.ts_end, now()))
   )`

// fmtCPAC formats a CPAC SQL template with the 4 positional args the templates
// use: %[1]s EvSchema, %[2]s RefSchema, %[3]s target table, %[4]s the aliased
// existing-row prefix ("ev" for the upsert/delete guards; "h" is baked into
// humanCoverPred already).
func fmtCPAC(tmpl, evSchema, refSchema, table, rowAlias string) string {
	return fmt.Sprintf(tmpl, evSchema, refSchema, table, rowAlias)
}

// RunOnceCPAC derives CPAC stops for one destination: correct (delete stale),
// then upsert. Both passes share the SAME scope + human-edit guards so a minted
// row always has a co-scoped cleaner (never an orphan open row — the
// int-overflow class from the EventMint↔deriver scope-mismatch bug).
func RunOnceCPAC(ctx context.Context, d Dest, cfg CPACConfig) (deleted, upserted int64, err error) {
	table := cfg.TargetTable
	if table == "" {
		table = DefaultCPACTargetTable
	}
	thr := cfg.ThresholdDefSec
	if thr <= 0 {
		thr = 300
	}
	del, err := d.Pool.Exec(ctx, fmtCPAC(cpacCorrectSQL, d.EvSchema, d.RefSchema, table, "ev"), cfg.Enterprises, thr)
	if err != nil {
		return 0, 0, fmt.Errorf("cpac correct pass: %w", err)
	}
	ups, err := d.Pool.Exec(ctx, fmtCPAC(cpacUpsertSQL, d.EvSchema, d.RefSchema, table, "ev"), cfg.Enterprises, thr)
	if err != nil {
		return del.RowsAffected(), 0, fmt.Errorf("cpac upsert pass: %w", err)
	}
	return del.RowsAffected(), ups.RowsAffected(), nil
}

// LoopCPAC runs the CPAC derivation on a fixed cadence for every destination.
// Caller (main.go) gates on CPAC_EVENT_DERIVATION_ENABLED before starting it.
func LoopCPAC(ctx context.Context, dests []Dest, cfg CPACConfig, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("CPAC stop deriver started (ADR-0010 §10.4, DARK)",
		slog.Int("destinations", len(dests)), slog.Int("enterprises", len(cfg.Enterprises)),
		slog.Int("threshold_default_sec", cfg.ThresholdDefSec), slog.String("target_table", cfg.TargetTable))
	jobs.Loop(ctx, jobs.Job{Name: "cpac-events-deriver", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			del, ups, err := RunOnceCPAC(ctx, d, cfg)
			if err != nil {
				logger.Warn("cpac deriver pass failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			if del+ups > 0 {
				logger.Info("cpac events derived", slog.String("dest", d.Name),
					slog.Int64("upserted", ups), slog.Int64("corrected", del))
			}
		}
		return firstErr
	}}, logger, obs)
}
