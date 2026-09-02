//go:build golden

// ADR-0022 V3 behavior-correctness acceptance suite. See doc.go for the
// why. Each scenario: rebuild a clean ephemeral schema → seed KNOWN
// rows → run the ACTUAL ported compute (rollup.*ForParity) → assert the
// numbers match hand-derived OEE arithmetic (shown in-comment).
//
//	Run: DATABASE_URL=postgres://user:pass@host/db go test -tags golden \
//	       ./internal/verdict -run Acceptance -v
package verdict

import (
	"context"
	"fmt"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/rollup"
)

// A self-contained schema modeling only the columns the ported compute
// touches (same technique as internal/rollup/golden_test.go). Schema
// name "v3" is passed to both the EvSchema and RefSchema slots of the
// ForParity accessors, so every %[1]s/%[2]s resolves to v3.*.
const schemaSQL = `
DROP SCHEMA IF EXISTS v3 CASCADE;
CREATE SCHEMA v3;

CREATE TABLE v3.equipments (
    id_equipment int PRIMARY KEY,
    id_site int, id_area int, id_enterprise int, tp_equipment int,
    production_speed double precision
);
CREATE TABLE v3.shifts (id_shift int PRIMARY KEY, cd_shift text);
CREATE TABLE v3.production_targets (
    id_equipment int, vl_day double precision, vl_week double precision,
    vl_month double precision, vl_hour double precision
);

-- shift grain (equipment + area) — columns the shift statements read/write
CREATE TABLE v3.equipment_runtime_shift (
    id_equipment int, ts_value timestamptz, ts_end timestamptz,
    ts_value_production timestamptz, id_shift int,
    target_customized boolean DEFAULT false, recalc_needed boolean DEFAULT false,
    cd_shift text,
    gross double precision, net double precision, scrap double precision,
    speed double precision, ideal_speed double precision,
    available_time double precision, running_time double precision,
    stopped_time double precision, planned_downtime double precision,
    ideal_production double precision, downtime double precision,
    changeover_time double precision, oee double precision,
    -- oee_a/oee_p/oee_q written by the shift events-update since ADR-0037 C
    -- (this fixture had drifted without them — RunShift's events-update needs them).
    oee_a double precision, oee_p double precision, oee_q double precision,
    proportional_target double precision,
    -- ADR-0036 §5A lineage columns (T0-2). REQUIRED: TestBoundedShiftDrain
    -- drives RunShift, whose stamp step writes these; without them RunShift errors.
    computed_at timestamptz, source_watermark timestamptz
);
CREATE TABLE v3.area_runtime_shift (
    id_area int, ts_value timestamptz, recalc_needed boolean DEFAULT false,
    computed_at timestamptz, source_watermark timestamptz
);

-- flow-plane inputs
CREATE TABLE v3.ca_agg_equipment_values_1hour (
    id_equipment int, ts_value timestamptz, ts_value_production timestamptz,
    state int, speed double precision, ideal_production_speed double precision,
    net_production_incr double precision, gross_production_incr double precision,
    id_shift int
);
CREATE TABLE v3.equipment_values (
    id_equipment int, ts_value timestamptz, ideal_production_speed double precision
);
CREATE TABLE v3.equipment_events (
    id_equipment int, ts_event timestamptz, ts_end timestamptz,
    status int, planned_downtime boolean, change_over boolean
);

-- PO grain (recalc consumer)
CREATE TABLE v3.production_orders (
    id_production_order bigint PRIMARY KEY,
    id_enterprise int NOT NULL, id_equipment int NOT NULL,
    status int NOT NULL, ts_start timestamptz NOT NULL,
    recalc_needed boolean NOT NULL DEFAULT false,
    gross_production double precision, net_production double precision,
    oee double precision, oee_quality double precision,
    oee_availability double precision, oee_performance double precision,
    speed double precision, available_time double precision,
    running_time double precision, stopped_time double precision,
    planned_downtime double precision, ideal_production_speed double precision,
    last_update timestamptz
);
CREATE TABLE v3.production_orders_runtime (
    id_production_order bigint NOT NULL, id_equipment int NOT NULL,
    runtime_timerange tstzrange NOT NULL,
    gross_production double precision, net_production double precision,
    running_time double precision, stopped_time double precision,
    available_time double precision, planned_downtime double precision,
    speed double precision
);

-- stub anchor: every hour maps to shift 1, 3h (10800s) size.
CREATE FUNCTION v3.piot_get_shift_hour_begin_by_equipment(eq int, t timestamptz)
  RETURNS TABLE (id_shift int, ts_begin timestamptz, shift_size double precision)
  AS 'SELECT 1, date_trunc(''day'', $2), 10800.0' LANGUAGE sql;
SET search_path TO v3, public;`

// tolerances: durations/counts are integers (exact); ratios computed in
// float64 the same way the SQL does — 1e-9 absolute is comfortable.
func approx(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func mustExec(t *testing.T, ctx context.Context, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(ctx, sql, args...); err != nil {
		t.Fatalf("exec failed: %v\nSQL: %.200s", err, sql)
	}
}

func reset(t *testing.T, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	mustExec(t, ctx, pool, schemaSQL)
}

// runShift executes one full shift pass (RunShift's statement sequence)
// against schema v3 in a single tx (temp tables need it). Prod defaults:
// no excluded areas, enterprise 6 excluded + machine-level.
func runShift(t *testing.T, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL search_path TO v3, public`); err != nil {
		t.Fatal(err)
	}
	for _, st := range rollup.ShiftStatementsForParity("v3", "v3") {
		var err error
		switch st.Name {
		case "eligible": // $1 exclAreas, $2 exclEnterprises, $3 machine-level
			_, err = tx.Exec(ctx, st.SQL, []int{}, []int{6}, []int{6})
		case "reflag": // $1 exclEnterprises, $2 machine-level
			_, err = tx.Exec(ctx, st.SQL, []int{6}, []int{6})
		default:
			_, err = tx.Exec(ctx, st.SQL)
		}
		if err != nil {
			t.Fatalf("shift %s: %v", st.Name, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
}

// runRecalc executes one PO-runtime-recalc pass (RunRecalc's sequence)
// against schema v3. window = prod default '1 month'; enterprise 6
// excluded (its recalc is owned by its own sync chain).
func runRecalc(t *testing.T, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	mustExec(t, ctx, pool, fmt.Sprintf(rollup.RecalcSQLForParity(), "v3", "v3"), "1 month", []int{6})
	mustExec(t, ctx, pool, fmt.Sprintf(rollup.ReflagRunningForParity(), "v3"))
	mustExec(t, ctx, pool, fmt.Sprintf(rollup.ReflagRecentForParity(), "v3"))
}

func TestAcceptanceVerdict(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set — needs ephemeral Postgres (same as -tags golden lane)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	// Tenant-parameterized: the identical scenarios must hold for both
	// the clean tenant (CPACK=3) and the customized tenant (Incoplast=4).
	// The compute is data-scoped by id_enterprise, so the ONLY thing that
	// changes between runs is the seeded enterprise id.
	for _, ent := range []int{3, 4} {
		t.Run(fmt.Sprintf("enterprise_%d", ent), func(t *testing.T) {
			scenarioOEECascadeShift(t, ctx, pool, ent)
			scenarioPOLifecycle(t, ctx, pool, ent)
			scenarioDowntimeClassification(t, ctx, pool, ent)
		})
	}
}

// scenarioOEECascadeShift — SCENARIO 1.
//
// A known shift: 3h long, one line (tp=3), fed by two hourly CAgg
// buckets and three events that tile the shift exactly.
//
//	CAgg buckets (state 6): gross 6000+4000 = 10000, net 5400+3600 = 9000,
//	                        ideal_production_speed 100/min, speed 90.
//	Events tiling [t0, t0+3h]:
//	   running (status 6)        2h  = 7200s
//	   planned stop (status 5)   0.5h= 1800s  planned_downtime=true
//	   unplanned (status 1)      0.5h= 1800s
//
// Derived event sums: ts_total 10800, ts_planned 1800, ts_running 7200.
//
//	available_time   = ts_total − ts_planned      = 10800 − 1800 = 9000 s
//	running_time     = 7200 s
//	ideal_production = (available_time/60)·ideal   = (9000/60)·100 = 15000
//	shift OEE (collapsed) = net / ideal_production  = 9000 / 15000 = 0.60
//
// The stored shift OEE is a SINGLE collapsed ratio, but it IS exactly
// Availability × Performance × Quality — the independent derivation that
// proves 0.60 is the RIGHT number (not just what both flows happen to
// emit):
//
//	Availability = running_time / available_time = 7200 / 9000        = 0.8000
//	Performance  = gross / (running_min · ideal)  = 10000 / (120·100)  = 0.8333…
//	Quality      = net / gross                    = 9000 / 10000       = 0.9000
//	A × P × Q    = 0.8 · 0.8333… · 0.9                                 = 0.60  ✓
//
// (Algebraically A·P·Q collapses to net/(available_min·ideal) — the
// running_min and gross terms cancel — which is the stored formula.)
func scenarioOEECascadeShift(t *testing.T, ctx context.Context, pool *pgxpool.Pool, ent int) {
	reset(t, ctx, pool)
	const eq = 100
	mustExec(t, ctx, pool, fmt.Sprintf(
		`INSERT INTO v3.equipments VALUES (%d, 1, 1, %d, 3, 100);`, eq, ent))
	mustExec(t, ctx, pool, `INSERT INTO v3.shifts VALUES (1, 'T1');`)
	// closed shift: started 4h ago, ended 1h ago (ts_end < now → no now() drift).
	mustExec(t, ctx, pool, fmt.Sprintf(`
		INSERT INTO v3.equipment_runtime_shift
		    (id_equipment, ts_value, ts_end, ts_value_production, id_shift, recalc_needed)
		VALUES (%d, now() - interval '4 hours', now() - interval '1 hour',
		        date_trunc('day', now() - interval '4 hours'), 1, true);`, eq))
	// two CAgg buckets inside the shift, both state 6.
	mustExec(t, ctx, pool, fmt.Sprintf(`
		INSERT INTO v3.ca_agg_equipment_values_1hour
		    (id_equipment, ts_value, ts_value_production, state, speed,
		     ideal_production_speed, net_production_incr, gross_production_incr, id_shift)
		VALUES
		    (%[1]d, now() - interval '4 hours', date_trunc('day', now() - interval '4 hours'), 6, 90, 100, 5400, 6000, 1),
		    (%[1]d, now() - interval '3 hours', date_trunc('day', now() - interval '4 hours'), 6, 90, 100, 3600, 4000, 1);`, eq))
	// three events tiling the shift exactly.
	mustExec(t, ctx, pool, fmt.Sprintf(`
		INSERT INTO v3.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
		VALUES
		    (%[1]d, now() - interval '4 hours', now() - interval '2 hours',   6, false, false),
		    (%[1]d, now() - interval '2 hours', now() - interval '90 minutes',5, true,  false),
		    (%[1]d, now() - interval '90 minutes', now() - interval '1 hour', 1, false, false);`, eq))

	runShift(t, ctx, pool)

	var gross, net, avail, running, planned, idealProd, oee float64
	if err := pool.QueryRow(ctx, `
		SELECT gross, net, available_time, running_time, planned_downtime, ideal_production, oee
		  FROM v3.equipment_runtime_shift WHERE id_equipment = $1`, eq).
		Scan(&gross, &net, &avail, &running, &planned, &idealProd, &oee); err != nil {
		t.Fatalf("read shift row: %v", err)
	}

	check := func(name string, got, want float64) {
		if !approx(got, want) {
			t.Errorf("[e%d] scenario1 %s: got %v want %v", ent, name, got, want)
		}
	}
	check("gross", gross, 10000)
	check("net", net, 9000)
	check("available_time", avail, 9000)
	check("running_time", running, 7200)
	check("planned_downtime", planned, 1800)
	check("ideal_production", idealProd, 15000)
	check("oee", oee, 0.60) // == A·P·Q = 0.8 · 0.8333… · 0.9 (see doc comment)

	// Re-derive A·P·Q from the stored fields and confirm the product is
	// the stored OEE — the correctness invariant, spelled out.
	availbty := running / avail            // 0.8
	quality := net / gross                 // 0.9
	perf := gross / ((running / 60) * 100) // 0.8333…, ideal_speed = 100
	if !approx(availbty*perf*quality, oee) {
		t.Errorf("[e%d] scenario1 A·P·Q %.6f·%.6f·%.6f = %.6f != stored oee %.6f",
			ent, availbty, perf, quality, availbty*perf*quality, oee)
	}
}

// scenarioPOLifecycle — SCENARIO 2.
//
// A PO that ran start→running→pause→finish. The lifecycle leaves two
// production_orders_runtime segments (before and after the pause); the
// recalc consumer sums them into the PO's OEE attribution.
//
//	segment 1: gross 3000, net 2700, avail 3600, run 2880, stop 900,  planned 900
//	segment 2: gross 3000, net 2700, avail 3600, run 2880, stop 900,  planned 900
//	Σ:         gross 6000, net 5400, avail 7200, run 5760, stop 1800, planned 1800
//	total = Σavail + Σplanned = 7200 + 1800 = 9000 ; ideal_speed = 100/min
//
// The recalc formulas (recalc.go, prod-verbatim), fully arithmetic:
//
//	oee_quality      = net / gross                  = 5400 / 6000            = 0.90
//	oee              = net / ((total−planned)/60·ideal)
//	                 = 5400 / ((9000−1800)/60·100)  = 5400 / (120·100)       = 0.45
//	oee_availability = run / avail                  = 5760 / 7200            = 0.80
//	oee_performance  = oee / (availability·quality) = 0.45 / (0.80·0.90)     = 0.625
//	check A·P·Q      = 0.80 · 0.625 · 0.90                                   = 0.45 = oee ✓
func scenarioPOLifecycle(t *testing.T, ctx context.Context, pool *pgxpool.Pool, ent int) {
	reset(t, ctx, pool)
	const eq, po = 110, 500
	mustExec(t, ctx, pool, fmt.Sprintf(
		`INSERT INTO v3.equipments VALUES (%d, 1, 1, %d, 3, 100);`, eq, ent))
	// status 3 (finished), started 3 days ago (>48h → recent-reflag does
	// NOT re-arm it → we can assert recalc_needed=false cleanly).
	mustExec(t, ctx, pool, fmt.Sprintf(`
		INSERT INTO v3.production_orders
		    (id_production_order, id_enterprise, id_equipment, status, ts_start,
		     recalc_needed, ideal_production_speed)
		VALUES (%d, %d, %d, 3, now() - interval '3 days', true, 100);`, po, ent, eq))
	mustExec(t, ctx, pool, fmt.Sprintf(`
		INSERT INTO v3.production_orders_runtime
		    (id_production_order, id_equipment, runtime_timerange,
		     gross_production, net_production, running_time, stopped_time,
		     available_time, planned_downtime, speed)
		VALUES
		    (%[1]d, %[2]d, tstzrange(now() - interval '2 days', now() - interval '2 days' + interval '1 hour'),
		     3000, 2700, 2880, 900, 3600, 900, 50),
		    (%[1]d, %[2]d, tstzrange(now() - interval '1 day', now() - interval '1 day' + interval '1 hour'),
		     3000, 2700, 2880, 900, 3600, 900, 50);`, po, eq))

	runRecalc(t, ctx, pool)

	var gross, net, oee, q, a, p, avail, run, stop, planned float64
	var recalc bool
	if err := pool.QueryRow(ctx, `
		SELECT gross_production, net_production, oee, oee_quality, oee_availability,
		       oee_performance, available_time, running_time, stopped_time,
		       planned_downtime, recalc_needed
		  FROM v3.production_orders WHERE id_production_order = $1`, po).
		Scan(&gross, &net, &oee, &q, &a, &p, &avail, &run, &stop, &planned, &recalc); err != nil {
		t.Fatalf("read PO: %v", err)
	}

	check := func(name string, got, want float64) {
		if !approx(got, want) {
			t.Errorf("[e%d] scenario2 %s: got %v want %v", ent, name, got, want)
		}
	}
	check("gross_production", gross, 6000)
	check("net_production", net, 5400)
	check("oee_quality", q, 0.90)
	check("oee", oee, 0.45)
	check("oee_availability", a, 0.80)
	check("oee_performance", p, 0.625)
	check("available_time", avail, 7200)
	check("running_time", run, 5760)
	check("stopped_time", stop, 1800)
	check("planned_downtime", planned, 1800)
	if recalc {
		t.Errorf("[e%d] scenario2 recalc_needed must be cleared after consume", ent)
	}
	if !approx(a*p*q, oee) {
		t.Errorf("[e%d] scenario2 A·P·Q %.6f != oee %.6f", ent, a*p*q, oee)
	}
}

// scenarioDowntimeClassification — SCENARIO 3.
//
// Two identical lines, identical shift, identical PHYSICAL behaviour:
// 2h running (status 6) then 1h of downtime. The ONLY difference is how
// the 1h downtime is CLASSIFIED — and that must change availability.
//
//	eq 201  downtime PLANNED   (status 5, planned_downtime=true)
//	eq 202  downtime UNPLANNED (status 1, planned_downtime=false)
//
// Planned downtime is EXCLUDED from available time (it is not held
// against the machine); unplanned downtime is not.
//
//	eq 201: ts_total 10800, ts_planned 3600
//	        available = 10800 − 3600 = 7200 ; running 7200
//	        availability = 7200 / 7200 = 1.000   (all available time was run)
//	eq 202: ts_total 10800, ts_planned 0
//	        available = 10800        ; running 7200
//	        availability = 7200 / 10800 = 0.6667  (the hour drags it down)
//
// Same net (900) → OEE also correctly diverges: planned 900/((7200/60)·100)
// = 900/12000 = 0.075 vs unplanned 900/((10800/60)·100) = 900/18000 = 0.05.
// This is the case data-parity alone can't catch: if the classification
// were dropped, BOTH would compute the unplanned number and F1/F3 would
// still agree — and be wrong.
func scenarioDowntimeClassification(t *testing.T, ctx context.Context, pool *pgxpool.Pool, ent int) {
	reset(t, ctx, pool)
	// ONE anchor for every seeded timestamp (bound as $1). This scenario
	// asserts available_time = ts_total − ts_planned where a downtime event
	// ends exactly at the shift end; the compute clips with
	// least(event.ts_end, shift.ts_end), so the two must be BYTE-equal.
	// now() evaluated in separate INSERTs drifts by ms → we anchor instead.
	// anchor is in the past (shift ends anchor−1h < rollup now()).
	anchor := time.Now().UTC()
	mustExec(t, ctx, pool, `INSERT INTO v3.shifts VALUES (1, 'T1');`)
	for _, eq := range []int{201, 202} {
		mustExec(t, ctx, pool, fmt.Sprintf(
			`INSERT INTO v3.equipments VALUES (%d, 1, 1, %d, 3, 100);`, eq, ent))
		mustExec(t, ctx, pool, fmt.Sprintf(`
			INSERT INTO v3.equipment_runtime_shift
			    (id_equipment, ts_value, ts_end, ts_value_production, id_shift, recalc_needed)
			VALUES (%d, $1::timestamptz - interval '4 hours', $1::timestamptz - interval '1 hour',
			        date_trunc('day', $1::timestamptz - interval '4 hours'), 1, true);`, eq), anchor)
		// one CAgg bucket so the value phase populates net/gross (needed
		// for a defined OEE); identical for both equipments.
		mustExec(t, ctx, pool, fmt.Sprintf(`
			INSERT INTO v3.ca_agg_equipment_values_1hour
			    (id_equipment, ts_value, ts_value_production, state, speed,
			     ideal_production_speed, net_production_incr, gross_production_incr, id_shift)
			VALUES (%d, $1::timestamptz - interval '4 hours', date_trunc('day', $1::timestamptz - interval '4 hours'),
			        6, 90, 100, 900, 1000, 1);`, eq), anchor)
		// running event (status 6), identical for both.
		mustExec(t, ctx, pool, fmt.Sprintf(`
			INSERT INTO v3.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
			VALUES (%d, $1::timestamptz - interval '4 hours', $1::timestamptz - interval '2 hours', 6, false, false);`, eq), anchor)
	}
	// eq 201: the downtime hour is PLANNED (status 5, planned=true).
	mustExec(t, ctx, pool, `
		INSERT INTO v3.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
		VALUES (201, $1::timestamptz - interval '2 hours', $1::timestamptz - interval '1 hour', 5, true, false);`, anchor)
	// eq 202: the SAME hour is UNPLANNED (status 1, planned=false).
	mustExec(t, ctx, pool, `
		INSERT INTO v3.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
		VALUES (202, $1::timestamptz - interval '2 hours', $1::timestamptz - interval '1 hour', 1, false, false);`, anchor)

	runShift(t, ctx, pool)

	read := func(eq int) (avail, run, planned, oee float64) {
		if err := pool.QueryRow(ctx, `
			SELECT available_time, running_time, planned_downtime, oee
			  FROM v3.equipment_runtime_shift WHERE id_equipment = $1`, eq).
			Scan(&avail, &run, &planned, &oee); err != nil {
			t.Fatalf("read eq %d: %v", eq, err)
		}
		return
	}

	// PLANNED tenant equipment.
	a1, r1, p1, oee1 := read(201)
	if !approx(a1, 7200) || !approx(r1, 7200) || !approx(p1, 3600) {
		t.Errorf("[e%d] scenario3 eq201(planned): avail=%v run=%v planned=%v want 7200/7200/3600", ent, a1, r1, p1)
	}
	if av := r1 / a1; !approx(av, 1.0) {
		t.Errorf("[e%d] scenario3 eq201 availability = %v want 1.0 (planned downtime excluded)", ent, av)
	}
	if !approx(oee1, 900.0/12000.0) {
		t.Errorf("[e%d] scenario3 eq201 oee = %v want %v", ent, oee1, 900.0/12000.0)
	}

	// UNPLANNED tenant equipment — same physical downtime, lower availability.
	a2, r2, p2, oee2 := read(202)
	if !approx(a2, 10800) || !approx(r2, 7200) || !approx(p2, 0) {
		t.Errorf("[e%d] scenario3 eq202(unplanned): avail=%v run=%v planned=%v want 10800/7200/0", ent, a2, r2, p2)
	}
	if av := r2 / a2; !approx(av, 2.0/3.0) {
		t.Errorf("[e%d] scenario3 eq202 availability = %v want 0.6667 (unplanned counts against it)", ent, av)
	}
	if !approx(oee2, 900.0/18000.0) {
		t.Errorf("[e%d] scenario3 eq202 oee = %v want %v", ent, oee2, 900.0/18000.0)
	}

	// the classification MUST move the number, else the flag is inert.
	if !(oee1 > oee2) {
		t.Errorf("[e%d] scenario3 planned OEE %v must exceed unplanned %v — classification had no effect", ent, oee1, oee2)
	}
}
