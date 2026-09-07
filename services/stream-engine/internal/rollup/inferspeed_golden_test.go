//go:build golden

// Golden-fixture test for the provisional ideal-speed inference
// (inferspeed.go). Proves the p95 estimator and EVERY guardrail on a hand-built
// counters-only stream: a tp=3 line with enough productive minutes gets its
// production_speed filled from the p95 of per-minute good-count throughput, while
// under-sampled / sub-floor / non-line / client-confirmed / already-inferred rows
// are handled exactly per spec.
//
// The statement is exercised in ISOLATION (via InferSpeedSQLForParity) against a
// controlled ca_agg_equipment_values_1min + equipments fixture, so the assertions
// are exact and independent of the live rollup.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run InferSpeed
package rollup

import (
	"context"
	"fmt"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestGoldenInferSpeed(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	// Self-contained schema: equipments WITH the production_speed_source marker
	// column (db/init/04), and the 1-min cagg the estimator reads.
	const schema = `
		DROP SCHEMA IF EXISTS ispeed CASCADE;
		CREATE SCHEMA ispeed;
		CREATE TABLE ispeed.equipments (
		    id_equipment int PRIMARY KEY,
		    tp_equipment int,
		    production_speed double precision,
		    production_speed_source text
		);
		CREATE TABLE ispeed.ca_agg_equipment_values_1min (
		    id_equipment int, ts_value timestamptz, gross_production_incr double precision
		);`

	// Fixture — six equipment, each probing one path:
	//   40 — tp=3, production_speed NULL, 300 productive minutes with rates
	//        1..100 (each value 3×) → p95 ≈ 95, ≥ min-minutes, ≥ floor → WRITTEN,
	//        marker set to 'inferred'.
	//   41 — tp=3, NULL, only 100 productive minutes (< 240) → SKIPPED (NULL).
	//   42 — tp=3, NULL, 300 productive minutes all rate 0.4 (p95 0.4 < floor 1)
	//        → SKIPPED (NULL).
	//   43 — tp=3, production_speed 500 marked 'client' (confirmed nameplate),
	//        plenty of samples → NEVER clobbered (stays 500 / 'client').
	//   44 — tp=3, production_speed 12 marked 'inferred' (a prior estimate),
	//        300 minutes rate ~95 → OVERWRITTEN with the fresh p95 (idempotent
	//        re-estimation of an inferred row).
	//   45 — tp=1 machine, NULL, plenty of samples → SKIPPED (tp guard: line-only).
	const fixture = `
		INSERT INTO ispeed.equipments (id_equipment, tp_equipment, production_speed, production_speed_source) VALUES
		    (40, 3, NULL, NULL),
		    (41, 3, NULL, NULL),
		    (42, 3, NULL, NULL),
		    (43, 3, 500, 'client'),
		    (44, 3, 12,  'inferred'),
		    (45, 1, NULL, NULL);
		-- 40: 300 productive minutes, per-minute rates cycle 1..100 (×3) → p95≈95
		INSERT INTO ispeed.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 40, now() - make_interval(mins => g), ((g % 100) + 1)
		  FROM generate_series(0, 299) g;
		-- 41: only 100 productive minutes (< 240)
		INSERT INTO ispeed.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 41, now() - make_interval(mins => g), ((g % 100) + 1)
		  FROM generate_series(0, 99) g;
		-- 42: 300 minutes but every rate 0.4 → p95 0.4 < floor 1.0
		INSERT INTO ispeed.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 42, now() - make_interval(mins => g), 0.4
		  FROM generate_series(0, 299) g;
		-- 43: confirmed nameplate — plenty of samples, must NOT be touched
		INSERT INTO ispeed.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 43, now() - make_interval(mins => g), ((g % 100) + 1)
		  FROM generate_series(0, 299) g;
		-- 44: prior inferred estimate — must be overwritten with fresh p95
		INSERT INTO ispeed.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 44, now() - make_interval(mins => g), ((g % 100) + 1)
		  FROM generate_series(0, 299) g;
		-- 45: tp=1 machine — line-only guard must skip it
		INSERT INTO ispeed.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 45, now() - make_interval(mins => g), ((g % 100) + 1)
		  FROM generate_series(0, 299) g;`

	for _, s := range []string{schema, fixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("ddl/fixture: %v", err)
		}
	}

	// The estimator, verbatim (single source): EvSchema=RefSchema=ispeed, all six
	// opted in, window 72h, min 240 minutes, p95, floor 1.0.
	stmt := fmt.Sprintf(InferSpeedSQLForParity(), "ispeed", pgIntArrayLiteral([]int{40, 41, 42, 43, 44, 45}),
		72, "0.95", "ispeed", 240, "1")
	if _, err := pool.Exec(ctx, stmt); err != nil {
		t.Fatalf("inferspeed: %v", err)
	}

	get := func(id int) (speed float64, speedNull bool, source string) {
		var sp *float64
		var src *string
		if err := pool.QueryRow(ctx,
			`SELECT production_speed, production_speed_source FROM ispeed.equipments WHERE id_equipment=$1`, id).
			Scan(&sp, &src); err != nil {
			t.Fatal(err)
		}
		if sp == nil {
			return 0, true, deref(src)
		}
		return *sp, false, deref(src)
	}

	// 40 — THE HEADLINE: p95 of rates 1..100 (×3) ≈ 95, written + marked inferred.
	sp, null, src := get(40)
	if null {
		t.Fatalf("eq40 production_speed is NULL, want a written p95 (~95)")
	}
	if math.Abs(sp-95) > 2 { // percentile_cont interpolation → ~95.05; round → 95
		t.Errorf("eq40 production_speed = %v, want ≈95 (p95 of 1..100)", sp)
	}
	if src != "inferred" {
		t.Errorf("eq40 production_speed_source = %q, want 'inferred'", src)
	}

	// 41 — under-sampled: left NULL (Performance stays honest, never fabricated).
	if _, null, _ := get(41); !null {
		t.Error("eq41 must stay NULL (only 100 < 240 productive minutes)")
	}

	// 42 — sub-floor: left NULL (p95 0.4 < floor 1.0).
	if _, null, _ := get(42); !null {
		t.Error("eq42 must stay NULL (p95 below floor)")
	}

	// 43 — confirmed nameplate: NEVER clobbered.
	sp, null, src = get(43)
	if null || sp != 500 || src != "client" {
		t.Errorf("eq43 = (%v,null=%v,%q), want 500/'client' UNTOUCHED", sp, null, src)
	}

	// 44 — prior inferred: overwritten with the fresh p95 (idempotent re-estimate).
	sp, null, src = get(44)
	if null || math.Abs(sp-95) > 2 || src != "inferred" {
		t.Errorf("eq44 = (%v,null=%v,%q), want ≈95/'inferred' (overwrote stale 12)", sp, null, src)
	}

	// 45 — tp=1 machine: skipped by the line-only guard.
	if _, null, _ := get(45); !null {
		t.Error("eq45 (tp=1) must stay NULL (inference is tp=3 line-only)")
	}
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
