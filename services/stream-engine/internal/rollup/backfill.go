// backfill.go — runtime-rollup-hour-backfill: drains STRANDED recalc_needed
// hour rows that the live rollup can't reach.
//
// The live hour rollup (RunHour) only considers ts_value >= now()-65min, so a
// row flagged recalc_needed OUTSIDE that window is never recomputed — it sits
// forever with a stale value, diverging F2/F3 from F1 on the bake's 24h/3d
// comparison windows. These accumulate after any burst that flags old rows: the
// 2026-07-10 incident + poison purge left ~9k stranded hour rows in
// packiot_analytics.
//
// This is NOT a second copy of the OEE math. It reuses the EXACT hour passes
// (hourValuesSQL/hourSpeedSQL/hourEventsSQL/hourTargetsSQL/cascades). Those are
// anchored on hour_elig.ts_value (the row's own hour), so the only thing that
// blocks them from recomputing an old hour is the recency filters (now()-65min,
// now()-6h) — pure chunk-pruning/row-selection optimizations for the live path.
// widenHourWindows() stretches those to the 10-day event-retention horizon (the
// events themselves only survive 10 days, so an older hour can't be recomputed
// anyway). Same math, wider slice.
//
// Bounded + oldest-first so a tick drains a fixed slice of the backlog without a
// load spike (which would re-create the very statement-timeout pressure we just
// fixed).
//
// ── DEDICATED ADVISORY-LOCK KEY (starvation fix, 2026-08-24) ─────────────────
// This USED to share the live rollup's per-dest "<dest>:runtime" advisory key so
// the two never wrote the same grain rows concurrently. Measured on staging F3,
// that shared key STARVED the backfill: the live hour/shift rollup's availability
// pass (rollup/availability.go "WITH bounds …") holds "<dest>:runtime" for ~28s
// and re-runs back-to-back (<2s gaps), a ~96% duty cycle. With a fixed 30s tick
// the backfill's pg_try_advisory_xact_lock aliased against the ~30s availability
// cycle and sampled the held window on essentially every tick → gotLock=false,
// silent skip, NO drain. hourReflagSQL re-flags the trailing ~3h band every 60s,
// so rows in [now-65min, now-3h) that only the backfill can recompute piled up
// (14k+ stranded, growing) — stale grain rows on the CPACK twin.
//
// The shared key is NOT needed for correctness: every hour pass (values, cascades,
// speed, events, oee) is driven by the hour_elig temp table and gated to
// `e.ts_value = el.ts_value`. The live eligible set is `ts_value >= now()-65min`;
// this backfill's is `ts_value < now()-65min AND >= now()-10d` — DISJOINT by the
// 65-minute boundary. So the live rollup and the backfill never UPDATE the same
// equipment_runtime_1hour / area_runtime_1hour row; the only cross-writer is the
// idempotent `recalc_needed = true` flag on equipment_runtime_1day (both may set
// it TRUE — safe under concurrency). Given that, the backfill takes its OWN key
// ("<dest>:runtime-backfill") so it no longer serializes behind the live rollup
// and gets its lock every tick — the backlog drains at the tick rate instead of
// once per lucky lock-gap.
package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// hourBackfillEligibleSQL populates hour_elig with the OLDEST recalc_needed hour
// rows that are (a) outside the live 65-minute window — RunHour owns recent — and
// (b) within the 10-day event-retention horizon — older can't be recomputed.
// %[3]d = LIMIT (per-tick batch size). Oldest-first so the backlog drains in
// chronological order and the bake window converges from its trailing edge in.
const hourBackfillEligibleSQL = `
	CREATE TEMP TABLE hour_elig ON COMMIT DROP AS
	SELECT h.id_equipment, h.ts_value, h.target_customized
	  FROM %[1]s.equipment_runtime_1hour h
	 WHERE h.recalc_needed
	   AND h.ts_value <  now() - interval '65 minutes'
	   AND h.ts_value >= now() - interval '10 days'
	   AND h.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	        WHERE tp_equipment > 1
	          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))
	 ORDER BY h.ts_value ASC
	 LIMIT %[3]d`

// hourBackfillClearSQL settles every backfilled row. The live rollup relies on
// re-selecting event-less hours each tick within its 65-min window; the backfill
// selects OLD rows, so an event-less hour (no matching row in the events pass →
// never cleared) would be re-selected every tick forever. Clearing the whole
// eligible batch here (after the passes have written their values) drains those
// too. recalc_needed is an internal processing flag, not a bake-compared column.
const hourBackfillClearSQL = `
	UPDATE %[1]s.equipment_runtime_1hour e SET recalc_needed = false
	  FROM hour_elig el
	 WHERE e.id_equipment = el.id_equipment AND e.ts_value = el.ts_value`

// widenHourWindows derives a backfill variant of a live hour-pass statement by
// stretching its recency optimizations to the 10-day event-retention horizon.
// The computation is anchored on el.ts_value, so this changes only which rows
// the pass touches — never how a touched row is computed. The events UPDATE
// guard (e.ts_value >= now()-6h), which actively blocks old-row writes, is
// widened by the same replacer.
func widenHourWindows(sql string) string {
	return strings.NewReplacer(
		"now() - interval '65 minutes'", "now() - interval '10 days'",
		"now() - interval '6 hour'", "now() - interval '10 days'",
	).Replace(sql)
}

// RunHourBackfill recomputes up to `limit` of the oldest stranded hour rows for
// one dest and returns how many it drained (0 = backlog empty for this dest).
// The cascade-day step flags the affected day rows, which the live day rollup
// (1-month window — never stranded) then recomputes, so the whole grain tree
// converges. No re-flag step: the backfill must never re-flag rows or it loops.
func RunHourBackfill(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int, limit int, ca CountersAvail) (int64, error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	// DEDICATED backfill key (see header): serializes the backfill against ITSELF
	// (single goroutine, so effectively a no-op guard) but NOT against the live
	// rollup — the two write disjoint grain rows (65-min boundary). Still TRY
	// (non-blocking) so a tick can never wedge on the main pool's 120s
	// statement_timeout; with the dedicated key the try now succeeds every tick.
	var gotLock bool
	if err := tx.QueryRow(ctx, `SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))`, d.Name+":runtime-backfill").Scan(&gotLock); err != nil {
		return 0, fmt.Errorf("advisory try-lock: %w", err)
	}
	if !gotLock {
		return 0, tx.Commit(ctx) // another backfill tick holds it — retry next tick
	}
	tag, err := tx.Exec(ctx, fmt.Sprintf(hourBackfillEligibleSQL, d.EvSchema, d.RefSchema, limit), exclAreas, exclEnterprises)
	if err != nil {
		return 0, fmt.Errorf("hour-backfill eligible: %w", err)
	}
	n := tag.RowsAffected()
	if n == 0 {
		return 0, tx.Commit(ctx) // backlog drained for this dest
	}
	// CRITICAL for the backfill (not the live path): the passes widen the cagg
	// join window to 10 days, which removes the live path's chunk-pruning. With
	// hour_elig an un-analyzed temp table, the planner has no row estimate and
	// scans the full 10-day range instead of driving from this ~200-row batch —
	// the values pass then blows the 5-min tick budget. Index + ANALYZE so the
	// planner drives from hour_elig via nested-loop index-seeks into the big
	// tables; the widened window collapses to a cheap redundant filter.
	if _, err := tx.Exec(ctx, `CREATE INDEX ON hour_elig (id_equipment, ts_value)`); err != nil {
		return 0, fmt.Errorf("hour-backfill index: %w", err)
	}
	if _, err := tx.Exec(ctx, `ANALYZE hour_elig`); err != nil {
		return 0, fmt.Errorf("hour-backfill analyze: %w", err)
	}
	steps := []struct{ name, sql string }{
		{"values", widenHourWindows(fmt.Sprintf(hourValuesSQL, d.EvSchema))},
		{"cascade-day", fmt.Sprintf(hourCascadeDaySQL, d.EvSchema)},
		{"cascade-area", fmt.Sprintf(hourCascadeAreaSQL, d.EvSchema, d.RefSchema)},
		{"speed", widenHourWindows(fmt.Sprintf(hourSpeedSQL, d.EvSchema, d.RefSchema))},
		{"events", widenHourWindows(fmt.Sprintf(hourEventsSQL, d.EvSchema))},
		{"targets", widenHourWindows(fmt.Sprintf(hourTargetsSQL, d.EvSchema, d.RefSchema))},
		{"clear", fmt.Sprintf(hourBackfillClearSQL, d.EvSchema)},
	}
	// FINALIZE the OEE decomposition — the live RunHour closes oee = oee_a·oee_p·oee_q
	// with a last pass (canonical A·P·Q reconcile when engaged, else the legacy oee_p
	// residual); the backfill previously OMITTED it, so a stranded hour it drained got
	// oee / oee_a / oee_q recomputed by the events pass while oee_p kept its stale
	// value → the identity broke on every backfilled row (measured live: CPACK tp=3
	// line hours with oee ≠ oee_a·oee_p·oee_q). Run the SAME finalize the live path
	// runs, widened to the backfill's 10-day horizon and AFTER the clear so the legacy
	// residual's `NOT recalc_needed` guard matches (the reconcile is guard-free).
	if ca.engagedCanonical() {
		steps = append(steps, struct{ name, sql string }{"oee-reconcile",
			widenHourWindows(fmt.Sprintf(hourOeeReconcileSQL, d.EvSchema))})
	} else {
		steps = append(steps, struct{ name, sql string }{"oee-p",
			widenHourWindows(fmt.Sprintf(hourOeePSQL, d.EvSchema))})
	}
	for _, s := range steps {
		if _, err := tx.Exec(ctx, s.sql); err != nil {
			return 0, fmt.Errorf("hour-backfill %s: %w", s.name, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return n, nil
}

// LoopHourBackfill drains the stranded-hour backlog in bounded batches until it
// is empty, then keeps ticking cheaply (each tick is a single indexed count once
// drained). Runs alongside LoopGrains; the shared advisory lock keeps them from
// racing on grain rows.
func LoopHourBackfill(ctx context.Context, dests []flows.Dest, exclAreas, exclEnterprises []int, limit int, ca CountersAvail, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("runtime-rollup-hour-backfill started (drains stranded recalc hours)",
		slog.Int("limit_per_tick", limit), slog.Duration("every", every))
	jobs.Loop(ctx, jobs.Job{Name: "runtime-rollup-hour-backfill", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			n, err := RunHourBackfill(ctx, d, exclAreas, exclEnterprises, limit, ca)
			if err != nil {
				logger.Warn("hour-backfill failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			if n > 0 {
				logger.Info("hour-backfill drained a batch", slog.String("dest", d.Name), slog.Int64("rows", n))
			}
		}
		return firstErr
	}}, logger, obs)
}
