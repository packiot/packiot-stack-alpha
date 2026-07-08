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
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// PER-TENANT BAKE (ADR-0020 / ADR-0021):
// The bake is now scoped per enterprise so a second staging tenant
// (Incoplast, enterprise 4 — stood up only AFTER the flip) can be
// validated on its OWN series without diluting CPACK's (enterprise 3)
// flip-readiness signal. Both gauges carry an `enterprise` label.
//
// THE FROZEN-GATE INVARIANT — CPACK MUST NOT CHANGE.
// The flip is gated on CPACK's numbers, so CPACK's SQL is FROZEN: the
// FIRST id in BAKE_ENTERPRISE_IDS (default "3") is the "gate tenant" and
// runs each surface's ORIGINAL, verbatim SQL — no enterprise filter
// injected — emitted under enterprise="3". Byte-identical to pre-change
// behaviour by construction (identical SQL string → identical result),
// and pinned in bake_test.go. Only ADDITIONAL enterprises (e.g. 4) run
// the positively-scoped variant (`ScopedSQL`, $1 = id_enterprise).
//
// Why freeze rather than positively-scope enterprise 3? Two surfaces
// (equipment_runtime_1hour / _1day) have a legacy side that EXCLUDES
// CPACK (see KNOWN DIVERGENCES below); positively scoping them to
// id_enterprise=3 would zero out `compared` (the inner join has no
// legacy CPACK rows to match) — a regression in the gate signal.
// Freezing sidesteps that entirely.
//
// PER-QUERY SCOPING MAP (surface -> what it compares -> how it scopes):
//   - equipment_runtime_shift:     gross/running_time on the shift grain;
//     scoped by l.id_equipment in equipments(id_enterprise=$1).
//   - production_orders_runtime:   gross_production/running_time per PO;
//     scoped by l.id_equipment in equipments(id_enterprise=$1).
//   - equipment_runtime_1hour:     gross/running_time, hour grain. Legacy
//     side EXCLUDES CPACK, so positive-scoping the gate (3) would zero
//     `compared`; gate stays FROZEN, only non-gate tenants scope.
//   - equipment_runtime_1day:      gross, day grain; same CPACK-exclusion
//     caveat as _1hour (gate frozen, non-gate scoped).
//   - uns_equipment_current_month: gross_production, month bucket;
//     scoped by id_equipment in equipments(id_enterprise=$1).
//   - uns_equipment_current_hour:  gross_production, hour bucket; same.
//   - uns_equipment_current_job:   id_order equality; same.
//   - uns_equipment_current_week:  gross_production, week bucket; same.
//   - equipment_events_closed:     ts_end of closed events (2s tol);
//     scoped by l.id_equipment in equipments(id_enterprise=$1).
//   - customer_reports_shift_06:   liveness of the pool report (ok=true).
//     NOT enterprise-scopable — keyed by customer_id=6 (the sync06/shift06
//     POOL tenant = enterprise 6, NOT a bake tenant). Kept a SINGLE global
//     series under enterprise="6".
var (
	surfaceDiff = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "bake_surface_mismatches",
		Help: "Rows differing between legacy (public) and Go (shadow_go_port) engines on a compared surface, per enterprise",
	}, []string{"surface", "enterprise"})
	surfaceCompared = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "bake_surface_compared",
		Help: "Rows compared on a surface this tick, per enterprise",
	}, []string{"surface", "enterprise"})
)

// surface holds a comparison query.
//
//   - SQL:       the ORIGINAL, verbatim query. The gate tenant runs this
//     unchanged (frozen-gate invariant). Takes NO parameters.
//   - ScopedSQL: the per-enterprise variant — identical to SQL plus an
//     `id_equipment ∈ equipments(id_enterprise = $1)` filter (nothing
//     else changes: same windows, same tolerances). Empty ("") means the
//     surface is NOT per-tenant scopable (a pool/global surface).
//   - Fixed:     for pool/global surfaces (ScopedSQL==""), the fixed
//     enterprise label to emit the single series under.
//
// Each surface: closed-window rows only (the parity drift classes),
// relative tolerance on production values, absolute on durations. The
// ScopedSQL variants add ONLY the enterprise filter — every time-window
// and tolerance clause is byte-identical to SQL (asserted in tests).
var surfaces = []struct{ Name, SQL, ScopedSQL, Fixed string }{
	{Name: "equipment_runtime_shift", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.equipment_runtime_shift l
	      JOIN shadow_go_port.equipment_runtime_shift g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_end < now() - interval '2 hours'
	       AND l.ts_value >= now() - interval '3 days') d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.equipment_runtime_shift l
	      JOIN shadow_go_port.equipment_runtime_shift g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_end < now() - interval '2 hours'
	       AND l.ts_value >= now() - interval '3 days'
	       AND l.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
	{Name: "production_orders_runtime", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.production_orders_runtime l
	      JOIN shadow_go_port.production_orders_runtime g
	        ON l.id_equipment = g.id_equipment
	       AND lower(l.runtime_timerange) = lower(g.runtime_timerange)
	     WHERE upper(l.runtime_timerange) < now() - interval '2 hours'
	       AND lower(l.runtime_timerange) >= now() - interval '3 days') d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.production_orders_runtime l
	      JOIN shadow_go_port.production_orders_runtime g
	        ON l.id_equipment = g.id_equipment
	       AND lower(l.runtime_timerange) = lower(g.runtime_timerange)
	     WHERE upper(l.runtime_timerange) < now() - interval '2 hours'
	       AND lower(l.runtime_timerange) >= now() - interval '3 days'
	       AND l.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},

	{Name: "equipment_runtime_1hour", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.equipment_runtime_1hour l
	      JOIN shadow_go_port.equipment_runtime_1hour g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_value >= now() - interval '2 days'
	       AND l.ts_value < date_trunc('hour', now() - interval '2 hours')) d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.equipment_runtime_1hour l
	      JOIN shadow_go_port.equipment_runtime_1hour g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_value >= now() - interval '2 days'
	       AND l.ts_value < date_trunc('hour', now() - interval '2 hours')
	       AND l.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
	{Name: "equipment_runtime_1day", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))) AS ok
	      FROM public.equipment_runtime_1day l
	      JOIN shadow_go_port.equipment_runtime_1day g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_value >= now() - interval '4 days'
	       AND l.ts_value < date_trunc('day', now())) d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))) AS ok
	      FROM public.equipment_runtime_1day l
	      JOIN shadow_go_port.equipment_runtime_1day g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_value >= now() - interval '4 days'
	       AND l.ts_value < date_trunc('day', now())
	       AND l.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
	{Name: "uns_equipment_current_month", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.02*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_month l
	      JOIN shadow_go_port.uns_equipment_current_month g USING (id_equipment)) d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.02*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_month l
	      JOIN shadow_go_port.uns_equipment_current_month g USING (id_equipment)
	     WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
	{Name: "uns_equipment_current_hour", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.05*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_hour l
	      JOIN shadow_go_port.uns_equipment_current_hour g USING (id_equipment)) d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.05*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_hour l
	      JOIN shadow_go_port.uns_equipment_current_hour g USING (id_equipment)
	     WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
	{Name: "uns_equipment_current_job", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (COALESCE(l.id_order::text,'') = COALESCE(g.id_order::text,'')) AS ok
	      FROM public.uns_equipment_current_job l
	      JOIN shadow_go_port.uns_equipment_current_job g USING (id_equipment)) d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (COALESCE(l.id_order::text,'') = COALESCE(g.id_order::text,'')) AS ok
	      FROM public.uns_equipment_current_job l
	      JOIN shadow_go_port.uns_equipment_current_job g USING (id_equipment)
	     WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
	// POOL/GLOBAL surface — keyed by customer_id=6 (the sync06/shift06 pool
	// tenant = enterprise 6, NEITHER a bake tenant nor CPACK). Not scopable
	// via id_enterprise; kept a single global series under enterprise="6".
	{Name: "customer_reports_shift_06", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT true AS ok FROM customer_reports.shift WHERE customer_id = 6) d`, Fixed: "6"},
	{Name: "equipment_events_closed", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(extract(epoch FROM (l.ts_end - g.ts_end))) < 2) AS ok
	      FROM public.equipment_events l
	      JOIN shadow_go_port.equipment_events g
	        ON l.id_equipment = g.id_equipment AND l.ts_event = g.ts_event
	     WHERE l.ts_event >= now() - interval '2 days'
	       AND l.ts_end IS NOT NULL AND g.ts_end IS NOT NULL) d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(extract(epoch FROM (l.ts_end - g.ts_end))) < 2) AS ok
	      FROM public.equipment_events l
	      JOIN shadow_go_port.equipment_events g
	        ON l.id_equipment = g.id_equipment AND l.ts_event = g.ts_event
	     WHERE l.ts_event >= now() - interval '2 days'
	       AND l.ts_end IS NOT NULL AND g.ts_end IS NOT NULL
	       AND l.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
	{Name: "uns_equipment_current_week", SQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.02*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_week l
	      JOIN shadow_go_port.uns_equipment_current_week g USING (id_equipment)) d`, ScopedSQL: `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.02*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_week l
	      JOIN shadow_go_port.uns_equipment_current_week g USING (id_equipment)
	     WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)) d`},
}

// runSurface executes one surface query and publishes its gauges under
// the given enterprise label. args is nil for the frozen gate (verbatim
// SQL, no params) and pool/global surfaces; []any{enterpriseID} for the
// positively-scoped variant.
func runSurface(ctx context.Context, pool *pgxpool.Pool, logger *slog.Logger, name, sql, entLabel string, args []any) error {
	var mismatches, compared int64
	if err := pool.QueryRow(ctx, sql, args...).Scan(&mismatches, &compared); err != nil {
		logger.Warn("bake surface failed", slog.String("surface", name),
			slog.String("enterprise", entLabel), slog.String("err", err.Error()))
		return err
	}
	surfaceDiff.WithLabelValues(name, entLabel).Set(float64(mismatches))
	surfaceCompared.WithLabelValues(name, entLabel).Set(float64(compared))
	if mismatches > 0 {
		logger.Warn("bake divergence", slog.String("surface", name), slog.String("enterprise", entLabel),
			slog.Int64("mismatches", mismatches), slog.Int64("compared", compared))
	}
	return nil
}

// plannedRun is one (surface × enterprise) query to execute this tick.
type plannedRun struct {
	Surface string
	SQL     string
	Label   string // enterprise label the gauges are emitted under
	Args    []any  // nil = verbatim (gate / pool); else []any{enterpriseID}
}

// planRuns expands the surface list against the configured enterprises.
// PURE (no I/O) so tests can pin the exact SQL + label set without a DB.
//
// The FIRST enterprise is the FROZEN GATE (default 3 / CPACK): it runs
// each surface's ORIGINAL verbatim SQL (Args nil) so its numbers and
// labels are byte-identical to pre-per-tenant behaviour. Additional
// enterprises run the positively-scoped ScopedSQL bound to their id.
// Pool/global surfaces (ScopedSQL=="") run exactly once under Fixed.
func planRuns(enterprises []int) []plannedRun {
	var out []plannedRun
	for _, s := range surfaces {
		if s.ScopedSQL == "" {
			out = append(out, plannedRun{s.Name, s.SQL, s.Fixed, nil})
			continue
		}
		for i, ent := range enterprises {
			if i == 0 {
				out = append(out, plannedRun{s.Name, s.SQL, strconv.Itoa(ent), nil})
			} else {
				out = append(out, plannedRun{s.Name, s.ScopedSQL, strconv.Itoa(ent), []any{ent}})
			}
		}
	}
	return out
}

// RunTick performs one comparison pass across all configured enterprises.
// The pool must reach both schemas (they share the staging DB).
func RunTick(ctx context.Context, pool *pgxpool.Pool, logger *slog.Logger, enterprises []int) error {
	var firstErr error
	for _, r := range planRuns(enterprises) {
		if err := runSurface(ctx, pool, logger, r.Surface, r.SQL, r.Label, r.Args); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// Loop schedules the comparator (F1-vs-F2 fidelity + F2-vs-F3 identity),
// running the surface pass per configured enterprise.
func Loop(ctx context.Context, pool *pgxpool.Pool, shadowPool *pgxpool.Pool, every time.Duration, enterprises []int, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("bake comparator started (F1-vs-F2 fidelity + F2-vs-F3 identity)",
		slog.Any("enterprises", enterprises))
	jobs.Loop(ctx, jobs.Job{Name: "bake-comparator", Every: every, Run: func(ctx context.Context) error {
		err := RunTick(ctx, pool, logger, enterprises)
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

// Register exposes the bake gauges on the registry the worker actually
// serves. The originals init()-registered on the DEFAULT registry —
// which /metrics never exposed, so THE GATE BOARD read empty (found by
// executing every panel query; the name-index hit was historical).
func Register(reg prometheus.Registerer) {
	reg.MustRegister(surfaceDiff, surfaceCompared, identityMismatch)
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
