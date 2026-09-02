// inferspeed.go — provisional ideal-speed inference from observed throughput,
// for counters-only tenants (bispharma) that have NO nameplate rated speed.
//
// THE PROBLEM. The rollup resolves OEE `ideal_speed` via a COALESCE fallback
// chain that ends in `equipments.production_speed` (see hour.go phase V /
// shift.go: `COALESCE(avg(ca.ideal_production_speed), locf, equipments.
// production_speed)`). A counters-only client emits NO PLC param 30701 and has
// no nameplate, so that column is NULL → ideal_speed 0 → oee_p cannot compute
// (stays null). #591 gave such a machine a CONFIGURED rated speed; this task is
// the sibling that DISCOVERS one from history when even that is absent.
//
// THE INFERENCE. Per opted-in tp=3 line equipment, we read the per-minute
// good-count rate from the 1-min continuous aggregate
// (<EvSchema>.ca_agg_equipment_values_1min, column `gross_production_incr` — the
// same per-minute increment availability.go sessionizes) over a trailing window
// (default 72h). Ideal := p95 of the PRODUCTIVE per-minute rates (rate > 0),
// via percentile_cont. p95 — NOT max — deliberately: a counter reset or a
// double-source phantom spikes a single minute to an absurd value; max would
// enshrine that garbage as the machine's rated speed, p95 sheds it while still
// capturing the true sustained ceiling (the machine's best honest minute).
//
// GUARDRAILS (all four, or we leave the column NULL — a null ideal_speed keeps
// Performance null, which is HONEST; a fabricated speed poisons every downstream
// OEE forever):
//   1. min-minutes: require >= N productive minutes in the window (default 240 =
//      4h of real production) before writing. Too few samples and p95 is noise.
//   2. floor: skip if p95 < a small threshold (default 1.0) — a machine that
//      barely ticked over has no meaningful rated speed to infer.
//   3. only-fill-provisional: UPSERT ONLY where production_speed IS NULL OR the
//      provisional marker production_speed_source = 'inferred'. A row marked
//      'client' is a CS-confirmed nameplate and is NEVER clobbered (see the
//      db/init/04 migration for the marker column + provenance semantics). The
//      write stamps 'inferred' so a later confirmed load (source='client') wins
//      permanently and inference backs off.
//   4. tp=3: the opt-in list (PROVISIONAL_SPEED_EQUIPMENTS) is the gate, but we
//      also assert tp_equipment = 3 defensively — this task is documented for
//      line-level rated speed only; a machine slipping into the opt-in CSV can't
//      accidentally get a line-shaped inference.
// Result is round()'d to integer (production_speed is integer) and the write is
// idempotent (re-running on a stable window reproduces the same value).
//
// FLAG-OFF PARITY. Wired as its OWN scheduled loop (LoopInferSpeed), spawned in
// main ONLY when PROVISIONAL_SPEED_INFERENCE_ENABLED. Disabled → no goroutine →
// zero statements → the executed stream is byte-identical, and InferSpeedSQL is
// deliberately NOT part of any *ForParity accessor the prod comparator diffs (the
// prod engine has no counters-only speed inference). The golden test drives
// InferSpeedSQLForParity() directly against a hand-built fixture.
//
// SINGLE WRITER (the #456 two-writer lesson). The ONLY write is the UPSERT to
// equipments.production_speed (+ the marker). No other worker task writes that
// column. Caveat: refsync mirrors equipments main->shadow via SELECT *, so on the
// shadow DB both refsync (copying main's value) and — if inference is also opted
// in on the F3 dest — this task touch the row. That is NOT the additive
// double-count of #456: inference is an IDEMPOTENT SET of a deterministic p95 to
// a NULL-or-'inferred' row, so both paths converge to the same value. For the
// production single-flow collapse there is exactly one dest and refsync is inert,
// giving a strict single writer.
package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// inferSpeedEvery is the fixed cadence of the inference loop. The trailing
// window is hours/days deep and production_speed changes slowly, so an hourly
// re-estimate is ample (and cheap — one grouped percentile scan per dest).
const inferSpeedEvery = time.Hour

// ProvisionalSpeed configures the counters-only ideal-speed inference (see
// config.go ProvisionalSpeed*). The zero value is disabled: LoopInferSpeed is
// never spawned, so the rollup is byte-identical to the no-inference path.
type ProvisionalSpeed struct {
	Enabled     bool
	Equipments  []int   // opted-in tp=3 id_equipment (empty → inert even if Enabled)
	WindowHours int     // trailing observation window (default 72)
	MinMinutes  int     // require >= this many productive minutes (default 240)
	Percentile  float64 // percentile_cont fraction (default 0.95)
	Floor       float64 // skip if the percentile < this (default 1.0)
}

// engaged reports whether the inference loop should run. Requires the master
// flag AND at least one opted-in equipment (an empty opt-in list makes ANY() of
// an empty array match nothing — inert, but skip the goroutine entirely).
func (p ProvisionalSpeed) engaged() bool {
	return p.Enabled && len(p.Equipments) > 0
}

// inferSpeedSQL — the provisional ideal-speed UPSERT. Format args:
//
//	%[1]s = EvSchema        (ca_agg_equipment_values_1min lives per-flow)
//	%[2]s = opted-in id array literal (pgIntArrayLiteral — config, not user input)
//	%[3]d = window hours
//	%[4]s = percentile fraction (e.g. "0.95")
//	%[5]s = RefSchema       (equipments — the reference plane the rollup reads)
//	%[6]d = min productive minutes
//	%[7]s = floor (e.g. "1")
//
// RETURNING surfaces exactly the rows written so RunInferSpeed can log per
// equipment what it wrote (id, p95, sample count). Guardrails 1/2 live in the
// UPDATE WHERE (min-minutes, floor); guardrail 3 (only-fill-provisional) is the
// `production_speed IS NULL OR production_speed_source = 'inferred'` predicate;
// guardrail 4 (tp=3) the `e.tp_equipment = 3` predicate.
const inferSpeedSQL = `
	WITH rates AS (
	    SELECT m.id_equipment,
	           percentile_cont(%[4]s) WITHIN GROUP (ORDER BY m.gross_production_incr) AS p95,
	           count(*) AS productive_minutes
	      FROM %[1]s.ca_agg_equipment_values_1min m
	     WHERE m.id_equipment = ANY(%[2]s)
	       AND m.ts_value >= now() - make_interval(hours => %[3]d)
	       AND m.gross_production_incr > 0
	     GROUP BY m.id_equipment
	)
	UPDATE %[5]s.equipments e SET
	       production_speed        = round(r.p95)::int,
	       production_speed_source = 'inferred'
	  FROM rates r
	 WHERE e.id_equipment = r.id_equipment
	   AND e.tp_equipment = 3
	   AND r.productive_minutes >= %[6]d
	   AND r.p95 >= %[7]s
	   AND (e.production_speed IS NULL OR e.production_speed_source = 'inferred')
	RETURNING e.id_equipment, e.production_speed, r.p95, r.productive_minutes`

// fmtFloat renders a config float as a bare SQL numeric literal (no exponent,
// no trailing noise): 0.95 → "0.95", 1.0 → "1". The values come from config,
// never user input, so inlining keeps the statement param-free like the rest of
// the rollup steps.
func fmtFloat(f float64) string {
	return strconv.FormatFloat(f, 'f', -1, 64)
}

// RunInferSpeed executes the inference UPSERT for one destination, reading the
// dest's EvSchema 1-min cagg and writing its RefSchema equipments. Logs each row
// it wrote. A no-op tick (nobody cleared the guardrails) writes nothing.
func RunInferSpeed(ctx context.Context, d flows.Dest, cfg ProvisionalSpeed, logger *slog.Logger) error {
	stmt := fmtInferSpeed(d, cfg)
	rows, err := d.Pool.Query(ctx, stmt)
	if err != nil {
		return err
	}
	defer rows.Close()
	var wrote int
	for rows.Next() {
		var id, speed, minutes int
		var p95 float64
		if err := rows.Scan(&id, &speed, &p95, &minutes); err != nil {
			return err
		}
		wrote++
		logger.Info("provisional ideal-speed inferred",
			slog.String("dest", d.Name),
			slog.Int("id_equipment", id),
			slog.Int("production_speed", speed),
			slog.Float64("p95", p95),
			slog.Int("productive_minutes", minutes))
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if wrote == 0 {
		logger.Debug("provisional ideal-speed: no equipment cleared the guardrails this tick",
			slog.String("dest", d.Name))
	}
	return nil
}

// fmtInferSpeed formats inferSpeedSQL for one dest — the single place the 7
// positional args are bound, shared by RunInferSpeed and the golden test.
func fmtInferSpeed(d flows.Dest, cfg ProvisionalSpeed) string {
	return fmt.Sprintf(inferSpeedSQL, d.EvSchema, pgIntArrayLiteral(cfg.Equipments), cfg.WindowHours,
		fmtFloat(cfg.Percentile), d.RefSchema, cfg.MinMinutes, fmtFloat(cfg.Floor))
}

// LoopInferSpeed schedules the inference on a fixed hourly cadence. Spawned by
// main only when the flag is on; a belt-and-suspenders engaged() check keeps it
// inert if somehow started with an empty opt-in list.
func LoopInferSpeed(ctx context.Context, dests []flows.Dest, cfg ProvisionalSpeed, logger *slog.Logger, obs jobs.Observer) {
	if !cfg.engaged() {
		logger.Info("provisional-speed-inference not engaged (flag off or no opted-in equipment) — loop not started")
		return
	}
	logger.Info("provisional-speed-inference started (counters-only ideal-speed from observed p95 throughput)",
		slog.Int("equipments", len(cfg.Equipments)),
		slog.Int("window_hours", cfg.WindowHours),
		slog.Int("min_minutes", cfg.MinMinutes),
		slog.Float64("percentile", cfg.Percentile),
		slog.Float64("floor", cfg.Floor))
	jobs.Loop(ctx, jobs.Job{Name: "provisional-speed-inference", Every: inferSpeedEvery, Timeout: 10 * time.Minute,
		Run: func(ctx context.Context) error {
			var firstErr error
			for _, d := range dests {
				if err := RunInferSpeed(ctx, d, cfg, logger); err != nil {
					logger.Warn("provisional-speed-inference pass failed",
						slog.String("dest", d.Name), slog.String("err", err.Error()))
					if firstErr == nil {
						firstErr = err
					}
				}
			}
			return firstErr
		}}, logger, obs)
}

// InferSpeedSQLForParity exposes the inference statement for the golden test.
// DELIBERATELY not part of HourStatementsForParity / ShiftStatementsForParity —
// those are diffed against the prod engine, which has no speed inference. Single
// source: the golden fixture formats this exactly as RunInferSpeed does.
func InferSpeedSQLForParity() string { return inferSpeedSQL }
