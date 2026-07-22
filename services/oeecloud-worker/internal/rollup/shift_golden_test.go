//go:build golden

// Golden-fixture test for the SHIFT-grain proportional_target proration
// (P1 regression fix — ADR-0029 D5 / #80). Freezes the elapsed-prorated
// SQL constant into CI so a revert to the full-shift form fails the build
// without needing staging.
//
// THE PROPERTY UNDER TEST (shiftTargetsSQL):
//
//	proportional_target = vl_day · (ts_total − ts_planned) / 86400
//
//	where ts_total = least(ts_end, now()) − ts_value (elapsed, capped).
//
// With vl_day set to 86400 the expected value collapses to the elapsed
// scheduled-productive SECONDS, so the assertions read directly:
//   - LIVE shift (2h into an 8h shift)  → 7200  (NOT the full 28800)
//   - tp=1 / tp=2 / tp=3 LIVE            → IDENTICAL (tp-agnostic)
//   - COMPLETED (past) shift             → 28800 (full/final target)
//   - LIVE shift with a 1h planned break → elapsed − planned (scheduled-productive)
//   - target_customized row              → untouched (never overwritten)
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run GoldenShift
package rollup

import (
	"context"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Self-contained shift schema (does NOT depend on the grain fixtures).
// vl_day = 86400 everywhere ⇒ proportional_target == elapsed-productive seconds.
const shiftGoldenSchema = `
	CREATE TABLE golden.shifts (id_shift int, cd_shift text);
	CREATE TABLE golden.area_runtime_shift (id_area int, ts_value timestamptz, recalc_needed boolean DEFAULT false);
	CREATE TABLE golden.production_targets (id_equipment int, vl_day double precision);
	CREATE TABLE golden.equipment_values (
	    id_equipment int, ts_value timestamptz, ideal_production_speed double precision
	);
	CREATE TABLE golden.equipment_events (
	    id_equipment int, ts_event timestamptz, ts_end timestamptz,
	    status int, planned_downtime boolean, change_over boolean
	);
	CREATE TABLE golden.ca_agg_equipment_values_1hour (
	    id_equipment int, ts_value timestamptz, ts_value_production timestamptz,
	    id_shift int, state int, speed double precision, ideal_production_speed double precision,
	    gross_production_incr double precision, net_production_incr double precision
	);
	CREATE TABLE golden.equipment_runtime_shift (
	    id_equipment int, ts_value timestamptz, ts_end timestamptz,
	    ts_value_production timestamptz, id_shift int, cd_shift text,
	    target_customized boolean DEFAULT false, recalc_needed boolean DEFAULT false,
	    gross double precision, net double precision, scrap double precision,
	    speed double precision, ideal_speed double precision,
	    available_time double precision, running_time double precision,
	    stopped_time double precision, planned_downtime double precision,
	    ideal_production double precision, downtime double precision,
	    changeover_time double precision, oee double precision,
	    oee_a double precision, oee_p double precision, oee_q double precision,
	    target double precision, proportional_target double precision
	);
	-- stub: shift_size 28800 (8h). NOTE: shift_size is intentionally UNUSED by
	-- the fixed formula (elapsed-based) — the LATERAL is retained only as the
	-- "shift-hour found" guard, so this row's mere existence lets targets fire.
	CREATE FUNCTION golden.piot_get_shift_hour_begin_by_equipment(eq int, t timestamptz)
	  RETURNS TABLE (id_shift int, ts_begin timestamptz, shift_size double precision)
	  AS 'SELECT 1, date_trunc(''day'', $2), 28800.0' LANGUAGE sql;
	SET search_path TO golden, public;`

// Six equipments, one shift row each (query by id_equipment, no ambiguity).
// All enterprise 35 / area 1 / site 1 so the tp>1 selector and the tp=1 +
// machine-level-enterprise selector both admit them.
const shiftGoldenFixture = `
	INSERT INTO golden.equipments VALUES
	    (30,1,1,35,1,100),  -- tp=1 machine, LIVE
	    (31,1,1,35,2,100),  -- tp=2 sector,  LIVE
	    (32,1,1,35,3,100),  -- tp=3 line,    LIVE
	    (33,1,1,35,1,100),  -- tp=1 machine, PAST (completed shift)
	    (34,1,1,35,3,100),  -- tp=3 line,    LIVE with a 1h planned break
	    (35,1,1,35,2,100);  -- tp=2 sector,  LIVE but target_customized
	INSERT INTO golden.production_targets VALUES
	    (30,86400),(31,86400),(32,86400),(33,86400),(34,86400),(35,86400);
	INSERT INTO golden.shifts VALUES (1,'S1');

	-- LIVE rows: 2h into an 8h shift (ts_value = now()-2h, ts_end = now()+6h).
	INSERT INTO golden.equipment_runtime_shift
	    (id_equipment, ts_value, ts_end, ts_value_production, id_shift, target_customized, recalc_needed, net, ideal_speed, proportional_target)
	VALUES
	    (30, now()-interval '2 hours', now()+interval '6 hours', date_trunc('day',now()), 1, false, true, 100, 100, 0),
	    (31, now()-interval '2 hours', now()+interval '6 hours', date_trunc('day',now()), 1, false, true, 100, 100, 0),
	    (32, now()-interval '2 hours', now()+interval '6 hours', date_trunc('day',now()), 1, false, true, 100, 100, 0),
	    -- PAST: fully-elapsed 8h shift a day ago (ts_end < now ⇒ ts_total == shift_size).
	    (33, now()-interval '1 day', now()-interval '1 day'+interval '8 hours', date_trunc('day',now()-interval '1 day'), 1, false, true, 100, 100, 0),
	    -- BREAK: 4h into an 8h shift (ts_value = now()-4h) with a 1h planned downtime.
	    (34, now()-interval '4 hours', now()+interval '4 hours', date_trunc('day',now()), 1, false, true, 100, 100, 0),
	    -- CUSTOM: operator-set target; proportional_target preset must survive.
	    (35, now()-interval '3 hours', now()+interval '5 hours', date_trunc('day',now()), 1, true, true, 100, 100, 99999);

	-- One running event (status 6, open) overlapping every shift row so each
	-- lands a shift_ev group (the events pass INNER-joins events).
	INSERT INTO golden.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
	VALUES
	    (30, now()-interval '2 hours', NULL, 6, false, false),
	    (31, now()-interval '2 hours', NULL, 6, false, false),
	    (32, now()-interval '2 hours', NULL, 6, false, false),
	    (33, now()-interval '1 day',   now()-interval '1 day'+interval '8 hours', 6, false, false),
	    (34, now()-interval '4 hours', NULL, 6, false, false),
	    (35, now()-interval '3 hours', NULL, 6, false, false),
	    -- eq34's 1h planned break (fully inside the elapsed window ⇒ ts_planned = 3600).
	    (34, now()-interval '2 hours', now()-interval '1 hour', 5, true, false);`

func TestGoldenShiftProportionalTarget(t *testing.T) {
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
	for _, s := range []string{goldenSchema, shiftGoldenSchema, shiftGoldenFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}

	// Run the full shift pass as one tx (ON COMMIT DROP temp tables need it).
	// machine-level enterprises = {35} so the tp=1 machines are eligible too.
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SET LOCAL search_path TO golden, public`); err != nil {
		t.Fatal(err)
	}
	for _, st := range ShiftStatementsForParity("golden", "golden") {
		// eligible/reflag take ($exclAreas,$exclEnt[,$machineEnt]); the middle
		// passes take none — try the 3-arg form, then 2-arg, then 0-arg.
		if _, err := tx.Exec(ctx, st.SQL, []int{}, []int{}, []int{35}); err != nil {
			if _, e2 := tx.Exec(ctx, st.SQL, []int{}, []int{35}); e2 != nil {
				if _, e3 := tx.Exec(ctx, st.SQL); e3 != nil {
					t.Fatalf("shift %s: %v / %v / %v", st.Name, err, e2, e3)
				}
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	prop := func(eq int) float64 {
		var v float64
		if err := pool.QueryRow(ctx,
			`SELECT COALESCE(proportional_target,-1) FROM golden.equipment_runtime_shift WHERE id_equipment=$1`, eq).
			Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	// tol absorbs the sub-second drift between fixture now() and targets now().
	near := func(got, want float64) bool { return math.Abs(got-want) < 90 }

	const fullShift = 28800.0 // the BUGGY full-shift value for an 8h shift

	// LIVE 2h/8h: elapsed-prorated ⇒ ~7200, and crucially NOT the full 28800.
	l30, l31, l32 := prop(30), prop(31), prop(32)
	if !near(l30, 7200) {
		t.Errorf("tp=1 LIVE proportional_target=%v, want ~7200 (elapsed 2h) — full-shift regression gives %v", l30, fullShift)
	}
	if l30 >= fullShift {
		t.Errorf("tp=1 LIVE proportional_target=%v is not below full shift %v — proration not applied", l30, fullShift)
	}
	// tp-agnostic: identical inputs ⇒ byte-identical proration across tp 1/2/3.
	if l30 != l31 || l30 != l32 {
		t.Errorf("proration is NOT tp-agnostic: tp1=%v tp2=%v tp3=%v (must be identical)", l30, l31, l32)
	}

	// PAST (completed) shift: ts_total == shift_size ⇒ full/final target, exact.
	if p33 := prop(33); p33 != fullShift {
		t.Errorf("PAST shift proportional_target=%v, want %v (completed ⇒ full target)", p33, fullShift)
	}

	// BREAK: 4h elapsed − 1h planned = 3h scheduled-productive ⇒ ~10800.
	// A denominator/basis that ignored the break would read ~14400.
	if p34 := prop(34); !near(p34, 10800) {
		t.Errorf("BREAK shift proportional_target=%v, want ~10800 (4h elapsed − 1h planned) — planned downtime not subtracted", p34)
	}

	// CUSTOM: never overwritten by the proration.
	if p35 := prop(35); p35 != 99999 {
		t.Errorf("target_customized proportional_target=%v, want 99999 (must be untouched)", p35)
	}

	// ADR-0037 C: the OEE waterfall is now written at the shift grain (was 0
	// everywhere). eq30 ran the full 2h elapsed window with no planned downtime,
	// so Availability = running/planned-production-time ≈ 1.0. And the composite
	// oee must equal a·p·q (Performance is the residual that closes it).
	var oee, a, p, q float64
	if err := pool.QueryRow(ctx,
		`SELECT COALESCE(oee,0),COALESCE(oee_a,0),COALESCE(oee_p,0),COALESCE(oee_q,0)
		   FROM golden.equipment_runtime_shift WHERE id_equipment=30`).
		Scan(&oee, &a, &p, &q); err != nil {
		t.Fatal(err)
	}
	if !(a > 0.9 && a <= 1.0+1e-9) {
		t.Errorf("shift oee_a=%v, want ≈1.0 (fully running, no planned downtime) — A/P/Q must be populated, not 0", a)
	}
	if math.Abs(oee-a*p*q) > 1e-6 {
		t.Errorf("OEE waterfall broken: oee=%v but a*p*q=%v (a=%v p=%v q=%v) — must satisfy oee = a·p·q", oee, a*p*q, a, p, q)
	}
}
