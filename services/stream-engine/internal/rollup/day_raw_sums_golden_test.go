//go:build golden

// Behavioural proof that the DAY rollup stores RAW time sums (2026-10-13,
// user decision "remove the day-length cap like P and Q"). It replaces the
// task #59 over-mint clamp proof, which asserted the opposite: the day's
// available/running/stopped/downtime were capped with LEAST(Σ hour, true
// production-day length).
//
// Policy since 2026-09-29 (#1482, "store raw, no clamps in data"): only the
// availability RATIO oee_a is capped at 1 (CHECK *_oee_bounds); P, Q, OEE and
// every time/count column are stored as measured. A day whose time sum exceeds
// its own wall-clock length is a data-quality signal (hour buckets mis-
// attributed to the production day, double-counted intervals), surfaced by
// invariant K7_day_time_gt_day_length (db/migrations/t-data-invariants-v10).
//
// The day-boundary function is stubbed from a per-equipment config table, so
// the fixture needs no real timezone/DST calendar. TYPE FIDELITY: the real
// equipment_oee_daily.ts_value is DATE, the real fn returns (timestamptz
// anchor, DATE production day), and the real hour/day time columns are
// INTEGER (gross/net real) — the fixture mirrors all of it, so an integer
// Σrunning/Σavailable division (oee_a → 0) cannot hide behind float columns.
//
//	201 — 25 × 3600 s buckets on an 86 400 s day ⇒ every time sum 90 000,
//	      stored RAW (was capped to 86 400); counts untouched; oee_a = 1.
//	202 — partial day (20 buckets) ⇒ plain sums (unchanged by the policy).
//	203 — DST fall-back, a legit 90 000 s day ⇒ 90 000 (unchanged).
//	204 — 25 buckets, running 3000 / available 3600 ⇒ 75 000 / 90 000 raw,
//	      oee_a = 0.8333 from the RAW sums (the cap made it 75000/86400).
//	205 — counter-only line, running 3600 > available 3000 ⇒ raw 90 000 /
//	      75 000 stored, oee_a CAPPED at 1 (the one capped ratio), and a low
//	      ideal makes P > 1, stored uncapped by the canonical reconcile.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run DayRawTimeSums
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

const dayRawSchema = `
	DROP SCHEMA IF EXISTS dayraw CASCADE;
	CREATE SCHEMA dayraw;
	SET search_path TO dayraw, public;

	CREATE TABLE dayraw.equipments (
	    id_equipment int PRIMARY KEY,
	    id_site int, id_area int, id_enterprise int, tp_equipment int
	);
	CREATE TABLE dayraw.equipment_oee_daily (
	    id_equipment int, ts_value date,
	    target_customized boolean DEFAULT false, recalc_needed boolean DEFAULT true,
	    oee real, oee_a real, oee_p real, oee_q real,
	    available_time integer, running_time integer,
	    stopped_time integer, planned_downtime integer,
	    ideal_production double precision, target double precision,
	    gross real, net real, downtime integer,
	    changeover_time integer, scrap real, speed real,
	    proportional_target real,
	    computed_at timestamptz, source_watermark timestamptz,
	    no_data_time integer NOT NULL DEFAULT 0, out_of_service_time integer NOT NULL DEFAULT 0
	);
	CREATE TABLE dayraw.equipment_oee_hourly (
	    id_equipment int, ts_value timestamptz, ts_value_production date,
	    available_time integer, running_time integer,
	    stopped_time integer, planned_downtime integer,
	    ideal_production double precision, target double precision,
	    gross real, net real, downtime integer,
	    changeover_time integer, scrap real, speed real,
	    proportional_target real,
	    no_data_time integer NOT NULL DEFAULT 0, out_of_service_time integer NOT NULL DEFAULT 0
	);

	-- Day-boundary stub: anchor(D) grows by true_len_s per calendar day, so
	-- consecutive anchors differ by the injected production-day length;
	-- ts_value_production is DATE, like the real fn.
	CREATE TABLE dayraw.day_len_cfg (id_equipment int PRIMARY KEY, true_len_s double precision);
	CREATE FUNCTION dayraw.piot_get_day_begin_by_equipment(eq int, t timestamptz)
	  RETURNS TABLE (ts_value timestamptz, ts_value_production date)
	  AS $$
	    SELECT
	      TIMESTAMPTZ '2000-01-01 00:00:00+00'
	        + make_interval(secs => (date_trunc('day', t)::date - DATE '2000-01-01')
	                                * (SELECT true_len_s FROM dayraw.day_len_cfg WHERE id_equipment = eq)),
	      date_trunc('day', t)::date;
	  $$ LANGUAGE sql;`

// dayRawHours inserts n hour buckets for one equipment on the fixture day.
func dayRawHours(id, n, avail, running, stopped, downtime int, ideal float64) string {
	return fmt.Sprintf(`
		INSERT INTO dayraw.equipment_oee_hourly
		    (id_equipment, ts_value, ts_value_production,
		     available_time, running_time, stopped_time, downtime,
		     planned_downtime, ideal_production, target, gross, net, changeover_time, scrap, speed, proportional_target)
		SELECT %d,
		       date_trunc('day', now() - interval '2 days') + make_interval(hours => g),
		       (now() - interval '2 days')::date,
		       %d, %d, %d, %d, 0, %g, 10, 120, 100, 0, 0, 50, 0
		  FROM generate_series(0, %d) g;`, id, avail, running, stopped, downtime, ideal, n-1)
}

func TestDayRawTimeSumsBehaviour(t *testing.T) {
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

	if _, err := pool.Exec(ctx, dayRawSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}

	setup := `
		SET search_path TO dayraw, public;
		INSERT INTO dayraw.equipments VALUES
		    (201,1,1,1,3),(202,1,1,1,3),(203,1,1,1,3),(204,1,1,1,3),(205,1,1,1,3);
		INSERT INTO dayraw.day_len_cfg VALUES
		    (201, 86400), (202, 86400), (203, 90000), (204, 86400), (205, 86400);
		INSERT INTO dayraw.equipment_oee_daily (id_equipment, ts_value)
		SELECT id, (now() - interval '2 days')::date FROM unnest(ARRAY[201,202,203,204,205]) id;` +
		dayRawHours(201, 25, 3600, 3600, 3600, 3600, 200) +
		dayRawHours(202, 20, 3600, 3000, 600, 600, 200) +
		dayRawHours(203, 25, 3600, 3600, 1800, 1800, 200) +
		dayRawHours(204, 25, 3600, 3000, 600, 600, 200) +
		// 205: counter-only line — running exceeds the available basis; ideal 60
		// per bucket < gross 120 ⇒ Performance > 1.
		dayRawHours(205, 25, 3000, 3600, 0, 0, 60)

	if _, err := pool.Exec(ctx, setup); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	// eligible + rollup (+ the canonical reconcile, as RunDay runs it when
	// OEE_CANONICAL_APQ is engaged) in one tx — day_elig is ON COMMIT DROP.
	run := func(withReconcile bool) {
		t.Helper()
		if _, err := pool.Exec(ctx, `UPDATE dayraw.equipment_oee_daily SET recalc_needed = true`); err != nil {
			t.Fatal(err)
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, `SET LOCAL search_path TO dayraw, public`); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, fmt.Sprintf(dayEligibleSQL, "dayraw", "dayraw"), []int{}, []int{}); err != nil {
			t.Fatalf("eligible: %v", err)
		}
		if _, err := tx.Exec(ctx, fmt.Sprintf(dayRollupSQL, "dayraw")); err != nil {
			t.Fatalf("rollup: %v", err)
		}
		if withReconcile {
			if _, err := tx.Exec(ctx, DayOeeReconcileSQLForParity("dayraw")); err != nil {
				t.Fatalf("reconcile: %v", err)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}

	type day struct {
		avail, running, stopped, downtime int64
		gross, net, oee, a, p, q          float64
	}
	get := func(id int) day {
		var d day
		if err := pool.QueryRow(ctx, `
			SELECT available_time, running_time, stopped_time, downtime, gross, net, oee, oee_a, oee_p, oee_q
			  FROM dayraw.equipment_oee_daily WHERE id_equipment = $1`, id).
			Scan(&d.avail, &d.running, &d.stopped, &d.downtime, &d.gross, &d.net, &d.oee, &d.a, &d.p, &d.q); err != nil {
			t.Fatalf("get %d: %v", id, err)
		}
		return d
	}
	near := func(a, b float64) bool { return math.Abs(a-b) < 1e-4 }

	for _, canonical := range []bool{false, true} {
		run(canonical)
		mode := map[bool]string{false: "legacy", true: "canonical"}[canonical]

		// 201 — the former over-mint case: the 90 000 s sums are stored RAW.
		d := get(201)
		for name, v := range map[string]int64{"available_time": d.avail, "running_time": d.running, "stopped_time": d.stopped, "downtime": d.downtime} {
			if v != 90000 {
				t.Errorf("[%s] 201 %s = %d — want the raw Σ 90000 (no day-length cap)", mode, name, v)
			}
		}
		if d.gross != 3000 || d.net != 2500 {
			t.Errorf("[%s] 201 counts changed: gross=%v net=%v (want 3000/2500)", mode, d.gross, d.net)
		}
		if !near(d.a, 1) {
			t.Errorf("[%s] 201 oee_a = %v — want 1 (running = available)", mode, d.a)
		}

		// 202 — sub-length day: plain sums.
		if d := get(202); d.avail != 72000 || d.running != 60000 || d.stopped != 12000 || d.downtime != 12000 {
			t.Errorf("[%s] 202 sums %+v (want 72000/60000/12000/12000)", mode, d)
		}

		// 203 — legit 25 h DST day.
		if d := get(203); d.avail != 90000 || d.running != 90000 {
			t.Errorf("[%s] 203 DST day avail=%d running=%d (want 90000/90000)", mode, d.avail, d.running)
		}

		// 204 — availability from the RAW sums, in float (integer division
		// would give 0; the old cap gave 75000/86400 = 0.868).
		d = get(204)
		if d.avail != 90000 || d.running != 75000 {
			t.Errorf("[%s] 204 avail=%d running=%d (want raw 90000/75000)", mode, d.avail, d.running)
		}
		if !near(d.a, 75000.0/90000.0) {
			t.Errorf("[%s] 204 oee_a = %v — want 0.8333 (Σrunning/Σavailable, raw, float)", mode, d.a)
		}

		// 205 — oee_a stays CAPPED at 1 while the raw times are kept; P > 1
		// is stored uncapped; Q = net/gross; oee = A·P·Q on the canonical path.
		d = get(205)
		if d.running != 90000 || d.avail != 75000 {
			t.Errorf("[%s] 205 running=%d avail=%d (want raw 90000/75000 — running > available kept)", mode, d.running, d.avail)
		}
		if d.a > 1 || !near(d.a, 1) {
			t.Errorf("[%s] 205 oee_a = %v — availability must be capped at exactly 1", mode, d.a)
		}
		if !near(d.q, 2500.0/3000.0) {
			t.Errorf("[%s] 205 oee_q = %v — want net/gross 0.8333", mode, d.q)
		}
		if canonical {
			// P = gross·available/(ideal·running) = 3000·75000/(1500·90000) = 1.6667
			if !near(d.p, 3000.0*75000/(1500.0*90000)) {
				t.Errorf("[canonical] 205 oee_p = %v — want 1.6667 (P uncapped)", d.p)
			}
			if !near(d.oee, d.a*d.p*d.q) {
				t.Errorf("[canonical] 205 oee = %v ≠ a·p·q = %v", d.oee, d.a*d.p*d.q)
			}
		} else if !near(d.oee, 2500.0/1500.0) {
			// legacy headline oee = Σnet / Σideal, uncapped.
			t.Errorf("[legacy] 205 oee = %v — want Σnet/Σideal 1.6667 (uncapped)", d.oee)
		}
	}
}
