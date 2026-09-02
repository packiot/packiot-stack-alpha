//go:build golden

// Golden-fixture test for the counters-only AVAILABILITY fallback
// (availability.go). Proves the idle-timeout inference on a hand-built
// state-less counters stream: a machine with production counters but NO state
// events, whose counter goes idle for a stretch, must land Availability < 1
// with the idle gap booked as stopped time.
//
// The fallback SQL is exercised in ISOLATION (via HourCountsAvailSQLForParity)
// against a controlled hour_elig temp table so the assertions are exact and
// independent of the live 65-minute eligibility window. Reuses goldenSchema +
// grainGoldenSchema (golden_test.go) for the table DDL.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run CountersAvail
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

func TestGoldenCountersAvail(t *testing.T) {
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

	// DDL: golden schema + grain tables (equipment_runtime_1hour,
	// ca_agg_equipment_values_1min, equipments) from the shared fixtures.
	for _, s := range []string{goldenSchema, grainGoldenSchema} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("ddl: %v", err)
		}
	}

	// Fixture: three counters-only, STATE-LESS machines (no equipment_events)
	// on a complete hour bucket 3h in the past (ts_total = 3600 exactly, and
	// every productive minute is < now()):
	//   eq 30 — idle gap: productive minutes 0-9 and 40-59 (a 31-min gap ≫
	//           the 300s idle timeout → the gap is stopped). Expected running
	//           = session A [0m .. 9m+300s→14m] = 840s + session B [40m ..
	//           min(59m+300s, 60m)=60m] = 1200s → 2040s; Availability 0.5667.
	//   eq 31 — every minute 0-59 productive → one session clipped to the
	//           bucket → running 3600s → Availability 1.0 (no idle penalty).
	//   eq 32 — NO production at all → running 0 → Availability 0 (a state-less
	//           machine that produced nothing is not "running").
	const fixture = `
		INSERT INTO golden.equipments VALUES
		    (30,1,1,3,1,147),(31,1,1,3,1,147),(32,1,1,3,1,147);
		-- the bucket: a complete hour, 3h old (within the fallback's 6h guard)
		CREATE TEMP TABLE hour_elig (id_equipment int, ts_value timestamptz);
		INSERT INTO hour_elig
		SELECT g, date_trunc('hour', now()) - interval '3 hours'
		  FROM (VALUES (30),(31),(32)) v(g);
		INSERT INTO golden.equipment_runtime_1hour
		    (id_equipment, ts_value, ts_value_production, gross, net, ideal_speed, recalc_needed)
		SELECT g, date_trunc('hour', now()) - interval '3 hours',
		       date_trunc('day', now()), 1000, 950, 147, true
		  FROM (VALUES (30),(31),(32)) v(g);
		-- eq 30: productive minutes 0-9 and 40-59 (idle gap between)
		INSERT INTO golden.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 30, date_trunc('hour', now()) - interval '3 hours' + make_interval(mins => m), 10
		  FROM generate_series(0,9) m
		UNION ALL
		SELECT 30, date_trunc('hour', now()) - interval '3 hours' + make_interval(mins => m), 10
		  FROM generate_series(40,59) m;
		-- eq 31: every minute productive
		INSERT INTO golden.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 31, date_trunc('hour', now()) - interval '3 hours' + make_interval(mins => m), 10
		  FROM generate_series(0,59) m;
		-- eq 32: no 1-min rows at all (totally idle hour)`

	// TEMP tables are connection-scoped; acquire ONE conn for fixture + pass.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SET search_path TO golden, public`); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, fixture); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	// The fallback pass, verbatim from availability.go (single source), with
	// the three machines opted in and a 300s idle timeout.
	stmt := fmt.Sprintf(HourCountsAvailSQLForParity(), "golden", pgIntArrayLiteral([]int{30, 31, 32}), 300)
	if _, err := conn.Exec(ctx, stmt); err != nil {
		t.Fatalf("counters-avail: %v", err)
	}

	type row struct {
		avail, running, stopped, oeeA, oeeQ, oee, planned float64
		recalc                                            bool
	}
	get := func(id int) row {
		var r row
		if err := conn.QueryRow(ctx,
			`SELECT available_time, running_time, stopped_time, oee_a, oee_q, oee,
			        planned_downtime, recalc_needed
			   FROM golden.equipment_runtime_1hour WHERE id_equipment=$1`, id).
			Scan(&r.avail, &r.running, &r.stopped, &r.oeeA, &r.oeeQ, &r.oee, &r.planned, &r.recalc); err != nil {
			t.Fatal(err)
		}
		return r
	}
	approx := func(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

	// eq 30 — THE HEADLINE: an idle gap drives Availability below 1, the gap
	// booked as stopped time.
	r30 := get(30)
	if !approx(r30.avail, 3600) {
		t.Errorf("eq30 available_time = %v, want 3600 (full bucket, no planned downtime)", r30.avail)
	}
	if !approx(r30.running, 2040) {
		t.Errorf("eq30 running_time = %v, want 2040 (session A 840 + session B 1200)", r30.running)
	}
	if !approx(r30.stopped, 1560) {
		t.Errorf("eq30 stopped_time = %v, want 1560 (the idle gap)", r30.stopped)
	}
	if !(r30.oeeA < 1.0) {
		t.Errorf("eq30 oee_a = %v, MUST be < 1 (idle gap is stopped)", r30.oeeA)
	}
	if !approx(r30.oeeA, 2040.0/3600.0) {
		t.Errorf("eq30 oee_a = %v, want %v", r30.oeeA, 2040.0/3600.0)
	}
	if !(r30.running < r30.avail) {
		t.Errorf("eq30 running (%v) must be < available (%v) — the gap is stopped", r30.running, r30.avail)
	}
	if !approx(r30.oeeQ, 0.95) {
		t.Errorf("eq30 oee_q = %v, want 0.95 (net 950 / gross 1000)", r30.oeeQ)
	}
	if !approx(r30.oee, 950.0/((3600.0/60.0)*147.0)) {
		t.Errorf("eq30 oee = %v, want %v", r30.oee, 950.0/((3600.0/60.0)*147.0))
	}
	if !approx(r30.planned, 0) {
		t.Errorf("eq30 planned_downtime = %v, want 0 (no events)", r30.planned)
	}
	if r30.recalc {
		t.Error("eq30 recalc_needed must be cleared by the fallback")
	}

	// eq 31 — continuous production: Availability settles at 1.0.
	r31 := get(31)
	if !approx(r31.running, 3600) || !approx(r31.oeeA, 1.0) {
		t.Errorf("eq31 running=%v oee_a=%v, want 3600 / 1.0 (no idle → full availability)", r31.running, r31.oeeA)
	}

	// eq 32 — no counts at all: running 0, Availability 0 (honest: a state-less
	// machine that produced nothing was not running).
	r32 := get(32)
	if !approx(r32.avail, 3600) || !approx(r32.running, 0) || !approx(r32.oeeA, 0) || r32.recalc {
		t.Errorf("eq32 = %+v, want avail 3600 / running 0 / oee_a 0 / cleared", r32)
	}
}
