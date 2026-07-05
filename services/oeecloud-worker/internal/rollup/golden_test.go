//go:build golden

// Golden-fixture test (methodology upgrade #3): runs the VERIFIED
// recalc SQL against an ephemeral Postgres with a hand-built fixture
// and asserts exact outputs. The staging parity harness proved the
// constants against prod's function (0/13,162); this test freezes
// that proof into CI — any regression to the SQL constants fails the
// build without needing staging.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run Golden
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

const goldenSchema = `
	DROP SCHEMA IF EXISTS golden CASCADE;
	CREATE SCHEMA golden;
	CREATE TABLE golden.production_orders (
	    id_production_order bigint PRIMARY KEY,
	    id_enterprise int NOT NULL,
	    id_equipment int NOT NULL,
	    status int NOT NULL,
	    ts_start timestamptz NOT NULL,
	    recalc_needed boolean NOT NULL DEFAULT false,
	    gross_production double precision,
	    net_production double precision,
	    oee double precision, oee_quality double precision,
	    oee_availability double precision, oee_performance double precision,
	    speed double precision, available_time double precision,
	    running_time double precision, stopped_time double precision,
	    planned_downtime double precision, total_time double precision,
	    ideal_production_speed double precision,
	    last_update timestamptz
	);
	CREATE TABLE golden.equipments (
	    id_equipment int PRIMARY KEY,
	    id_site int, id_enterprise int, tp_equipment int,
	    production_speed double precision
	);
	CREATE TABLE golden.production_orders_runtime (
	    id_production_order bigint NOT NULL,
	    id_equipment int NOT NULL,
	    runtime_timerange tstzrange NOT NULL,
	    gross_production double precision, net_production double precision,
	    running_time double precision, stopped_time double precision,
	    available_time double precision, planned_downtime double precision,
	    speed double precision, ideal_speed double precision
	);`

// Fixture: PO 1 has two closed runtime windows (sums verify);
// PO 2 is eligible with NO runtime rows (the IF-FOUND zero+clear
// semantics the harness caught — the regression this test exists
// to prevent); PO 3 is excluded by enterprise.
const goldenFixture = `
	INSERT INTO golden.production_orders
	    (id_production_order, id_enterprise, id_equipment, status, ts_start, recalc_needed,
	     gross_production, net_production, ideal_production_speed, total_time, planned_downtime)
	VALUES
	    (1, 35, 10, 2, now() - interval '2 days', true, 999, 999, 120, 7200, 600),
	    (2, 35, 11, 3, now() - interval '3 days', true, 777, 777, 100, 3600, 0),
	    (3, 6, 12, 2, now() - interval '2 days', true, 555, 555, 100, 3600, 0);
	INSERT INTO golden.equipments VALUES (10,1,35,3,100),(11,1,35,3,100),(12,1,6,3,100);
	INSERT INTO golden.production_orders_runtime
	    (id_production_order, id_equipment, runtime_timerange,
	     gross_production, net_production, running_time, stopped_time,
	     available_time, planned_downtime, speed)
	VALUES
	    (1, 10, tstzrange(now() - interval '2 days', now() - interval '47 hours'), 100, 90, 3000, 600, 3600, 0, 50),
	    (1, 10, tstzrange(now() - interval '46 hours', now() - interval '45 hours'), 60, 55, 2400, 1200, 3600, 0, 40);`

func TestGoldenRecalc(t *testing.T) {
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
	for _, s := range []string{goldenSchema, goldenFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	// The verified statement, verbatim from the port (single source).
	if _, err := pool.Exec(ctx, fmt.Sprintf(RecalcSQLForParity(), "golden", "golden"),
		"1 month", []int{6}); err != nil {
		t.Fatalf("recalc: %v", err)
	}

	type po struct {
		gross, net, quality float64
		recalc              bool
	}
	get := func(id int) po {
		var p po
		if err := pool.QueryRow(ctx,
			`SELECT COALESCE(gross_production,-1), COALESCE(net_production,-1),
			        COALESCE(oee_quality,-1), recalc_needed
			   FROM golden.production_orders WHERE id_production_order=$1`, id).
			Scan(&p.gross, &p.net, &p.quality, &p.recalc); err != nil {
			t.Fatal(err)
		}
		return p
	}
	approx := func(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

	// PO 1: summed windows (100+60, 90+55), quality 145/160, cleared.
	p1 := get(1)
	if !approx(p1.gross, 160) || !approx(p1.net, 145) || !approx(p1.quality, 145.0/160.0) || p1.recalc {
		t.Errorf("PO1 golden mismatch: %+v", p1)
	}
	// PO 2: THE IF-FOUND SEMANTICS — no runtime rows ⇒ ZEROED and
	// CLEARED (prod behavior the harness caught; an inner-join
	// regression would leave 777/true here).
	p2 := get(2)
	if !approx(p2.gross, 0) || !approx(p2.net, 0) || p2.recalc {
		t.Errorf("PO2 IF-FOUND regression: %+v (must be zeroed + cleared)", p2)
	}
	// PO 3: excluded enterprise — untouched.
	p3 := get(3)
	if !approx(p3.gross, 555) || !p3.recalc {
		t.Errorf("PO3 exclusion regression: %+v (must be untouched)", p3)
	}
}
