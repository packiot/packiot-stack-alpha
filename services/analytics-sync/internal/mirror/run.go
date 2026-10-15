package mirror

import (
	"context"
	"log/slog"
	"time"
)

// RunForever runs hot passes every Interval, a full pass every FullEvery (and first), and records the MR*
// invariants every InvariantEvery. beat is called after every pass that completed (converged or not), so a
// wedged loop — not a diverging one — turns /healthz red; divergence is the invariants' and alerts' job.
func (r *Reflector) RunForever(ctx context.Context, beat func()) error {
	var lastInv time.Time
	t := time.NewTimer(0)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
		full := r.lastFull.IsZero() || time.Since(r.lastFull) >= r.cfg.FullEvery
		res, err := r.Pass(ctx, full)
		ent := itoa(r.ent)
		r.m.Unclassified.Set(float64(len(r.Unclassified)))
		switch {
		case err != nil:
			kind := "hot"
			if full {
				kind = "full"
			}
			r.m.Passes.WithLabelValues(ent, kind, "error").Inc()
			r.log.Error("reflect pass failed (staging unchanged)", slog.String("err", err.Error()))
		case res.Skipped:
			r.m.Passes.WithLabelValues(ent, res.Kind, "skipped").Inc()
			beat()
		default:
			result := "unconverged"
			if res.Converged {
				result = "converged"
				r.lastConverged = time.Now()
				r.m.LastConverged.WithLabelValues(ent).Set(float64(r.lastConverged.Unix()))
			}
			if full {
				r.lastFull = time.Now()
			}
			r.m.Passes.WithLabelValues(ent, res.Kind, result).Inc()
			lvl := slog.LevelDebug
			if res.Changed > 0 || !res.Converged {
				lvl = slog.LevelInfo
			}
			r.log.Log(ctx, lvl, "reflect pass", slog.String("kind", res.Kind), slog.Bool("converged", res.Converged),
				slog.Bool("dry_run", r.cfg.DryRun), slog.Int("tables", res.Tables), slog.Int("changed", res.Changed),
				slog.Int("upserts", res.Upserts), slog.Int("deletes", res.Deletes), slog.Int("divergent", res.Divergent),
				slog.Int("guarded", res.Guarded), slog.Int("errors", res.Errors), slog.Int("unconverged", res.Unconverged),
				slog.Int("staging_writes", res.StagingWrites))
			beat()
		}
		if r.cfg.InvariantEvery > 0 && time.Since(lastInv) >= r.cfg.InvariantEvery && err == nil {
			lastInv = time.Now()
			inv, ierr := r.Invariants(ctx)
			if ierr == nil {
				ierr = r.RecordInvariants(ctx, inv)
			}
			if ierr != nil {
				r.log.Error("invariants not recorded", slog.String("err", ierr.Error()))
			}
		}
		t.Reset(r.cfg.Interval)
	}
}
