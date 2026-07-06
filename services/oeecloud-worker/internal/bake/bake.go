// Package bake — the ADR-0016 side-by-side comparator (and
// methodology upgrade #6): staging F1 still runs the LEGACY piot
// engine while F2 runs the Go engine, both fed by the same mirrored
// stream. This job continuously diffs the surfaces where the two
// engines SHOULD agree and exports the result as metrics — the
// consolidation gate's evidence accumulates by itself.
//
// KNOWN DIVERGENCES (encoded, not compared):
//   - Legacy day2/hour rollups EXCLUDE CPACK (enterprise hardcoded in
//     prod bodies); the Go engine keeps CPACK via config. Surfaces
//     where the engines' scopes differ are compared on the shared
//     scope only, or via the shift grain (both engines include CPACK).
//   - Timing classes (the parity taxonomy): open/current buckets and
//     re-flag bands drift with now() — windows exclude them.
//
// Both flows live in the SAME database (public vs shadow_go_port) —
// diffs are single SQL statements.
package bake

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

var (
	surfaceDiff = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "bake_surface_mismatches",
		Help: "Rows differing between legacy (public) and Go (shadow_go_port) engines on a compared surface",
	}, []string{"surface"})
	surfaceCompared = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "bake_surface_compared",
		Help: "Rows compared on a surface this tick",
	}, []string{"surface"})
)

func init() {
	prometheus.MustRegister(surfaceDiff, surfaceCompared)
}

// Each surface: closed-window rows only (the parity drift classes),
// relative tolerance on production values, absolute on durations.
var surfaces = []struct{ Name, SQL string }{
	{"equipment_runtime_shift", `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.equipment_runtime_shift l
	      JOIN shadow_go_port.equipment_runtime_shift g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_end < now() - interval '2 hours'
	       AND l.ts_value >= now() - interval '3 days') d`},
	{"production_orders_runtime", `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.production_orders_runtime l
	      JOIN shadow_go_port.production_orders_runtime g
	        ON l.id_equipment = g.id_equipment
	       AND lower(l.runtime_timerange) = lower(g.runtime_timerange)
	     WHERE upper(l.runtime_timerange) < now() - interval '2 hours'
	       AND lower(l.runtime_timerange) >= now() - interval '3 days') d`},
	{"uns_equipment_current_week", `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.02*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_week l
	      JOIN shadow_go_port.uns_equipment_current_week g USING (id_equipment)) d`},
}

// RunTick performs one comparison pass. The pool must reach both
// schemas (they share the staging DB).
func RunTick(ctx context.Context, pool *pgxpool.Pool, logger *slog.Logger) error {
	var firstErr error
	for _, s := range surfaces {
		var mismatches, compared int64
		if err := pool.QueryRow(ctx, s.SQL).Scan(&mismatches, &compared); err != nil {
			logger.Warn("bake surface failed", slog.String("surface", s.Name), slog.String("err", err.Error()))
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		surfaceDiff.WithLabelValues(s.Name).Set(float64(mismatches))
		surfaceCompared.WithLabelValues(s.Name).Set(float64(compared))
		if mismatches > 0 {
			logger.Warn("bake divergence", slog.String("surface", s.Name),
				slog.Int64("mismatches", mismatches), slog.Int64("compared", compared))
		}
	}
	return firstErr
}

// Loop schedules the comparator (F1-vs-F2 fidelity + F2-vs-F3 identity).
func Loop(ctx context.Context, pool *pgxpool.Pool, shadowPool *pgxpool.Pool, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("bake comparator started (F1-vs-F2 fidelity + F2-vs-F3 identity)")
	jobs.Loop(ctx, jobs.Job{Name: "bake-comparator", Every: every, Run: func(ctx context.Context) error {
		err := RunTick(ctx, pool, logger)
		if ierr := RunIdentityTick(ctx, pool, shadowPool, logger); ierr != nil && err == nil {
			err = ierr
		}
		return err
	}}, logger, obs)
}

// ── F2-vs-F3 IDENTITY surfaces ────────────────────────────────────
// F2 (shadow_go_port) and F3 (packiot_shadow) run the SAME Go engine
// on the SAME fan-out inputs — their outputs must be IDENTICAL, not
// merely tolerant. Cross-database, so each side computes an aggregate
// fingerprint and Go compares. Any drift = a real divergence in the
// dual-emit path (deploy-order gap, failed fanout leg, schema drift).

var identityMismatch = prometheus.NewGaugeVec(prometheus.GaugeOpts{
	Name: "bake_identity_mismatch",
	Help: "1 if F2 and F3 fingerprints differ on a surface (must be 0)",
}, []string{"surface"})

func init() {
	prometheus.MustRegister(identityMismatch)
}

// Fingerprint: count + rounded sums over a closed recent window.
var identitySurfaces = []struct{ Name, SQL string }{
	{"equipment_values_24h", `
	SELECT count(*)::text || '|' || COALESCE(sum(net_production_incr)::numeric(20,3),0)::text
	    || '|' || COALESCE(sum(gross_production_incr)::numeric(20,3),0)::text
	  FROM %s.equipment_values
	 WHERE ts_value >= date_trunc('hour', now() - interval '25 hours')
	   AND ts_value < date_trunc('hour', now() - interval '1 hour')`},
	{"equipment_runtime_shift_3d", `
	SELECT count(*)::text || '|' || COALESCE(sum(gross)::numeric(20,3),0)::text
	    || '|' || COALESCE(sum(running_time)::numeric(20,1),0)::text
	  FROM %s.equipment_runtime_shift
	 WHERE ts_value >= now() - interval '3 days' AND ts_end < now() - interval '2 hours'`},
	{"production_orders_runtime_3d", `
	SELECT count(*)::text || '|' || COALESCE(sum(gross_production)::numeric(20,3),0)::text
	  FROM %s.production_orders_runtime
	 WHERE lower(runtime_timerange) >= now() - interval '3 days'
	   AND upper(runtime_timerange) < now() - interval '2 hours'`},
}

// RunIdentityTick compares F2 vs F3 fingerprints.
func RunIdentityTick(ctx context.Context, f2 *pgxpool.Pool, f3 *pgxpool.Pool, logger *slog.Logger) error {
	if f3 == nil {
		return nil
	}
	var firstErr error
	for _, s := range identitySurfaces {
		var a, b string
		if err := f2.QueryRow(ctx, fmt.Sprintf(s.SQL, "shadow_go_port")).Scan(&a); err != nil {
			logger.Warn("identity F2 failed", slog.String("surface", s.Name), slog.String("err", err.Error()))
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if err := f3.QueryRow(ctx, fmt.Sprintf(s.SQL, "public")).Scan(&b); err != nil {
			logger.Warn("identity F3 failed", slog.String("surface", s.Name), slog.String("err", err.Error()))
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if a == b {
			identityMismatch.WithLabelValues(s.Name).Set(0)
		} else {
			identityMismatch.WithLabelValues(s.Name).Set(1)
			logger.Warn("F2/F3 IDENTITY BROKEN", slog.String("surface", s.Name),
				slog.String("f2", a), slog.String("f3", b))
		}
	}
	return firstErr
}
