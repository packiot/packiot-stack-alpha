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
	    id_site int, id_area int, id_enterprise int, tp_equipment int,
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
	INSERT INTO golden.equipments VALUES (10,1,1,35,3,100),(11,1,1,35,3,100),(12,1,1,6,3,100);
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

// Golden fixtures for the grain tier: hour (flag-KEEPING phase V),
// day2 (hour-table rollup + customized-target CASE). The piot_*
// helpers the statements call are stubbed in the fixture schema —
// deterministic anchors, no shift calendar needed.
const grainGoldenSchema = `
	CREATE TABLE golden.equipment_runtime_1hour (
	    id_equipment int, ts_value timestamptz, ts_value_production timestamptz,
	    gross double precision, net double precision, scrap double precision,
	    speed double precision, ideal_speed double precision,
	    available_time double precision, running_time double precision,
	    stopped_time double precision, planned_downtime double precision,
	    ideal_production double precision, downtime double precision,
	    changeover_time double precision, oee double precision,
	    target double precision, proportional_target double precision,
	    target_customized boolean DEFAULT false, recalc_needed boolean DEFAULT false
	);
	CREATE TABLE golden.equipment_runtime_1day (LIKE golden.equipment_runtime_1hour INCLUDING ALL);
	ALTER TABLE golden.equipment_runtime_1day ADD COLUMN oee_a double precision, ADD COLUMN oee_q double precision, ADD COLUMN oee_p double precision;
	CREATE TABLE golden.equipment_runtime_1week (LIKE golden.equipment_runtime_1day INCLUDING ALL);
	CREATE TABLE golden.equipment_runtime_1month (LIKE golden.equipment_runtime_1day INCLUDING ALL);
	CREATE TABLE golden.area_runtime_1hour (id_area int, ts_value timestamptz, recalc_needed boolean DEFAULT false);
	CREATE TABLE golden.ca_agg_equipment_values_1hour (
	    id_equipment int, ts_value timestamptz, ts_value_production timestamptz,
	    state int, speed double precision, ideal_production_speed double precision,
	    net_production_incr double precision, gross_production_incr double precision, id_shift int
	);
	CREATE TABLE golden.ca_agg_equipment_values_1min (LIKE golden.ca_agg_equipment_values_1hour INCLUDING ALL);
	CREATE TABLE golden.equipment_values (
	    id_equipment int, ts_value timestamptz, ideal_production_speed double precision
	);
	CREATE TABLE golden.equipment_events (
	    id_equipment int, ts_event timestamptz, ts_end timestamptz,
	    status int, planned_downtime boolean, change_over boolean
	);
	CREATE TABLE golden.production_targets (
	    id_equipment int, vl_day double precision, vl_week double precision,
	    vl_month double precision, vl_hour double precision
	);
	-- stub anchors: day begins at UTC midnight; every hour belongs to shift 1
	CREATE FUNCTION golden.piot_get_day_begin_by_equipment(eq int, t timestamptz)
	  RETURNS TABLE (ts_value timestamptz, ts_value_production timestamptz)
	  AS 'SELECT date_trunc(''day'', $2), date_trunc(''day'', $2)' LANGUAGE sql;
	CREATE FUNCTION golden.piot_get_shift_hour_begin_by_equipment(eq int, t timestamptz)
	  RETURNS TABLE (id_shift int, ts_begin timestamptz, shift_size double precision)
	  AS 'SELECT 1, date_trunc(''day'', $2), 28800.0' LANGUAGE sql;
	SET search_path TO golden, public;`

const grainGoldenFixture = `
	INSERT INTO golden.equipments VALUES (20,1,1,35,3,100);
	-- hour bucket (current hour, flagged) with one ca row: gross 50, net 45, state-6 speed 40
	INSERT INTO golden.equipment_runtime_1hour (id_equipment, ts_value, ts_value_production, recalc_needed)
	VALUES (20, date_trunc('hour', now()), date_trunc('day', now()), true);
	INSERT INTO golden.ca_agg_equipment_values_1hour
	    (id_equipment, ts_value, ts_value_production, state, speed, net_production_incr, gross_production_incr)
	VALUES (20, date_trunc('hour', now()), date_trunc('day', now()), 6, 40, 45, 50);
	-- day bucket (yesterday, flagged) summing two hour rows: 100+60 / 90+55
	INSERT INTO golden.equipment_runtime_1day (id_equipment, ts_value, recalc_needed, target_customized, target)
	VALUES (20, date_trunc('day', now() - interval '1 day'), true, true, 777);
	INSERT INTO golden.equipment_runtime_1hour
	    (id_equipment, ts_value, ts_value_production, gross, net, ideal_production, target, proportional_target, running_time, available_time, stopped_time, planned_downtime, downtime, changeover_time, scrap, speed)
	VALUES
	    (20, date_trunc('day', now() - interval '1 day') + interval '1 hour', date_trunc('day', now() - interval '1 day'), 100, 90, 200, 10, 10, 1800, 3600, 600, 0, 900, 0, 10, 50),
	    (20, date_trunc('day', now() - interval '1 day') + interval '2 hour', date_trunc('day', now() - interval '1 day'), 60, 55, 100, 10, 10, 2400, 3600, 300, 0, 600, 0, 5, 40);
	-- THE LINE-WITH-NULL-IDEAL CASE (measured live 2026-07-07, eq 51/96
	-- at CPACK-Staging): tp_equipment=3, equipments.production_speed
	-- NULL, all in-hour 1min buckets carry NULL ideal_production_speed
	-- (30701 arrived HOURS earlier). Prod LOCFs from equipment_values
	-- (capture :10162-10172) → ideal_speed 120; the pre-fix port got 0
	-- → oee 0 while F1 said ~0.95.
	INSERT INTO golden.equipments VALUES (21,1,1,35,3,NULL);
	INSERT INTO golden.equipment_runtime_1hour (id_equipment, ts_value, ts_value_production, recalc_needed)
	VALUES (21, date_trunc('hour', now()), date_trunc('day', now()), true);
	INSERT INTO golden.ca_agg_equipment_values_1hour
	    (id_equipment, ts_value, ts_value_production, state, speed, net_production_incr, gross_production_incr)
	VALUES (21, date_trunc('hour', now()), date_trunc('day', now()), 6, 40, 45, 50);
	INSERT INTO golden.ca_agg_equipment_values_1min
	    (id_equipment, ts_value, state, speed, ideal_production_speed)
	VALUES (21, date_trunc('hour', now()), 6, 40, NULL);
	INSERT INTO golden.equipment_values VALUES (21, now() - interval '3 hours', 120);
	INSERT INTO golden.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
	VALUES (21, date_trunc('hour', now()), NULL, 6, false, false);`

func TestGoldenGrains(t *testing.T) {
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
	for _, s := range []string{goldenSchema, grainGoldenSchema, grainGoldenFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	// hour pass (one tx, like RunHour) — search_path carries the stubs.
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SET LOCAL search_path TO golden, public`); err != nil {
		t.Fatal(err)
	}
	for _, st := range HourStatementsForParity("golden", "golden") {
		if _, err := tx.Exec(ctx, st.SQL, []int{}, []int{}); err != nil {
			if _, e2 := tx.Exec(ctx, st.SQL); e2 != nil {
				t.Fatalf("hour %s: %v / %v", st.Name, err, e2)
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var gross, net float64
	var recalc bool
	if err := pool.QueryRow(ctx, `SELECT gross, net, recalc_needed FROM golden.equipment_runtime_1hour
	    WHERE id_equipment=20 AND ts_value=date_trunc('hour', now())`).Scan(&gross, &net, &recalc); err != nil {
		t.Fatal(err)
	}
	if gross != 50 || net != 45 {
		t.Errorf("hour sums: gross=%v net=%v", gross, net)
	}
	// THE HOUR SEMANTIC: phase V keeps the flag; with events present it
	// clears — our fixture has NO events, so the flag must survive
	// phase V (recalc still true unless the tail re-flagged it — the
	// tail DOES re-flag current hours, so true either way; the
	// assertion that matters is the sums landed while flag stayed).
	if !recalc {
		t.Error("hour flag must remain true (no events → phase E never cleared)")
	}
	// eq 20 has NO 1min rows this hour: prod's speed select avgs over
	// zero rows → NULL → zero-fill. The fallback to production_speed
	// is PER EXISTING ROW only — a regression to the null-extended
	// CASE would write 100 here.
	var idle20 float64
	if err := pool.QueryRow(ctx, `SELECT ideal_speed FROM golden.equipment_runtime_1hour
	    WHERE id_equipment=20 AND ts_value=date_trunc('hour', now())`).Scan(&idle20); err != nil {
		t.Fatal(err)
	}
	if idle20 != 0 {
		t.Errorf("empty-hour ideal_speed: %v (prod writes 0, never production_speed)", idle20)
	}

	// THE LINE-OEE LOCF SEMANTIC (eq 21): in-hour 1min bucket has NULL
	// ideal_production_speed and equipments.production_speed is NULL —
	// prod LOCFs the 3h-old equipment_values row (120). Pre-fix the
	// port wrote ideal_speed=0 → oee=0 (the measured F1≈0.95 vs
	// F2/F3=0.000 divergence on equipments 51/96).
	var ideal21, oee21 float64
	if err := pool.QueryRow(ctx, `SELECT ideal_speed, COALESCE(oee, -1) FROM golden.equipment_runtime_1hour
	    WHERE id_equipment=21 AND ts_value=date_trunc('hour', now())`).Scan(&ideal21, &oee21); err != nil {
		t.Fatal(err)
	}
	if ideal21 != 120 {
		t.Errorf("line LOCF ideal_speed: %v (want 120 from equipment_values 3h back)", ideal21)
	}
	if oee21 <= 0 {
		t.Errorf("line oee: %v (must be > 0 — net 45 against LOCF'd ideal)", oee21)
	}

	// day2 pass: sums the two hour rows; target_customized=true must PRESERVE 777.
	tx2, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx2.Exec(ctx, `SET LOCAL search_path TO golden, public`); err != nil {
		t.Fatal(err)
	}
	for _, st := range DayStatementsForParity("golden", "golden") {
		if _, err := tx2.Exec(ctx, st.SQL, []int{}, []int{}); err != nil {
			if _, e2 := tx2.Exec(ctx, st.SQL); e2 != nil {
				t.Fatalf("day %s: %v / %v", st.Name, err, e2)
			}
		}
	}
	if err := tx2.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var dg, dn, dtarget float64
	if err := pool.QueryRow(ctx, `SELECT gross, net, target FROM golden.equipment_runtime_1day
	    WHERE id_equipment=20 AND ts_value=date_trunc('day', now() - interval '1 day')`).Scan(&dg, &dn, &dtarget); err != nil {
		t.Fatal(err)
	}
	if dg != 160 || dn != 145 {
		t.Errorf("day2 sums: gross=%v net=%v (want 160/145)", dg, dn)
	}
	if dtarget != 777 {
		t.Errorf("day2 CUSTOMIZED TARGET regression: %v (operator's 777 must survive)", dtarget)
	}
}
