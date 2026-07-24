//go:build golden

// Golden-fixture test for ADR-0037 finding (c) (medallion R3c): a changeover
// event must depress Availability instead of being removed from the clock.
//
// Runs the SAME shift pass twice over an identical PAST (fully-closed) shift —
// once with the classification flag OFF (prod-verbatim) and once ON — and asserts
// the exact availability arithmetic moves the changeover time out of the planned
// bucket and into the availability-loss basis, while leaving changeover_time (the
// report) and gross/net untouched.
//
// PAST shift ⇒ ts_total = ts_end − ts_value = 8h = 28800s (deterministic; no
// wall-clock clipping). Events, both fully inside and closed:
//
//   - running (status 6)     [ts_value,     ts_value+7h] → 25200s
//
//   - changeover (status 5)  [ts_value+7h,  ts_value+8h] →  3600s
//     planned_downtime=true, change_over=true (as the 13-downtime-reasons seed)
//
//     metric              OFF (today)                 ON (ADR-0037 c)
//     ts_planned          3600 (changeover=planned)   0    (changeover excluded)
//     available_time      28800−3600 = 25200          28800−0 = 28800
//     oee_a               25200/25200 = 1.000         25200/28800 = 0.875  ← depressed
//     planned_downtime    3600                         0
//     changeover_time     3600                         3600  ← unchanged (report intact)
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run GoldenChangeover
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

// eq 40: tp=3 line, enterprise 35 (admitted by the shift grain's tp>1 selector).
const changeoverGoldenFixture = `
	INSERT INTO golden.equipments VALUES (40,1,1,35,3,100);
	INSERT INTO golden.production_targets VALUES (40, 86400);
	INSERT INTO golden.shifts VALUES (1,'S1');
	-- PAST fully-elapsed 8h shift a day ago ⇒ ts_total = 28800.
	INSERT INTO golden.equipment_runtime_shift
	    (id_equipment, ts_value, ts_end, ts_value_production, id_shift, target_customized, recalc_needed, net, gross, ideal_speed)
	VALUES
	    (40, now()-interval '1 day', now()-interval '1 day'+interval '8 hours', date_trunc('day',now()-interval '1 day'), 1, false, true, 90, 100, 100);
	-- 7h running + 1h changeover (planned_downtime=true, change_over=true).
	INSERT INTO golden.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
	VALUES
	    (40, now()-interval '1 day',              now()-interval '1 day'+interval '7 hours', 6, false, false),
	    (40, now()-interval '1 day'+interval '7 hours', now()-interval '1 day'+interval '8 hours', 5, true, true);`

type shiftAvail struct {
	available, running, planned, changeover, oeeA float64
}

// runShiftPass runs the frozen parity shift statement list, but swaps the
// events-bank predicate for the requested classification — the ONLY difference
// between the off and on runs. Everything else is byte-identical to the parity
// (prod-verbatim) path.
func runShiftPassChangeover(ctx context.Context, t *testing.T, pool *pgxpool.Pool, changeoverAvailability bool) shiftAvail {
	t.Helper()
	// Re-flag the row so the pass re-selects it.
	if _, err := pool.Exec(ctx, `UPDATE golden.equipment_runtime_shift SET recalc_needed = true WHERE id_equipment = 40`); err != nil {
		t.Fatal(err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL search_path TO golden, public`); err != nil {
		t.Fatal(err)
	}
	for _, st := range ShiftStatementsForParity("golden", "golden") {
		sql := st.SQL
		if st.Name == "events-bank" {
			// The one line under test: reclassify the ts_planned bucket.
			sql = fmt.Sprintf(shiftEventsSQL, "golden", plannedDowntimeExpr(changeoverAvailability))
		}
		if _, err := tx.Exec(ctx, sql, []int{}, []int{}, []int{35}); err != nil {
			if _, e2 := tx.Exec(ctx, sql, []int{}, []int{35}); e2 != nil {
				if _, e3 := tx.Exec(ctx, sql); e3 != nil {
					t.Fatalf("shift %s: %v / %v / %v", st.Name, err, e2, e3)
				}
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var a shiftAvail
	if err := pool.QueryRow(ctx,
		`SELECT COALESCE(available_time,0), COALESCE(running_time,0), COALESCE(planned_downtime,0),
		        COALESCE(changeover_time,0), COALESCE(oee_a,0)
		   FROM golden.equipment_runtime_shift WHERE id_equipment = 40`).
		Scan(&a.available, &a.running, &a.planned, &a.changeover, &a.oeeA); err != nil {
		t.Fatal(err)
	}
	return a
}

func TestGoldenChangeoverAvailability(t *testing.T) {
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
	// goldenSchema + shiftGoldenSchema define the tables + the shift-hour stub;
	// changeoverGoldenFixture adds eq 40's past shift + its two events.
	for _, s := range []string{goldenSchema, shiftGoldenSchema, changeoverGoldenFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	eq := func(got, want float64) bool { return math.Abs(got-want) < 1e-6 }

	off := runShiftPassChangeover(ctx, t, pool, false)
	on := runShiftPassChangeover(ctx, t, pool, true)

	// OFF (today): changeover is planned ⇒ removed from the clock. A ≈ 1.0.
	if !eq(off.planned, 3600) {
		t.Errorf("OFF planned_downtime=%v, want 3600 (changeover counted as planned)", off.planned)
	}
	if !eq(off.available, 25200) {
		t.Errorf("OFF available_time=%v, want 25200 (28800 − 3600 changeover)", off.available)
	}
	if !eq(off.oeeA, 1.0) {
		t.Errorf("OFF oee_a=%v, want 1.0 (changeover removed from the availability clock)", off.oeeA)
	}

	// ON (ADR-0037 c): changeover excluded from planned ⇒ stays inside the clock,
	// depressing Availability to 25200/28800 = 0.875.
	if !eq(on.planned, 0) {
		t.Errorf("ON planned_downtime=%v, want 0 (changeover no longer counted as planned)", on.planned)
	}
	if !eq(on.available, 28800) {
		t.Errorf("ON available_time=%v, want 28800 (changeover back inside planned-production-time)", on.available)
	}
	if !eq(on.oeeA, 25200.0/28800.0) {
		t.Errorf("ON oee_a=%v, want %v (0.875 — Availability depressed by changeover loss)", on.oeeA, 25200.0/28800.0)
	}
	if !(on.oeeA < off.oeeA) {
		t.Errorf("changeover-availability must DEPRESS Availability: on=%v not < off=%v", on.oeeA, off.oeeA)
	}

	// Invariants across the flag: the changeover REPORT and the running time are
	// untouched — only the planned/available split moves. The moved-out planned
	// time equals exactly the changeover time (nothing created or lost).
	if !eq(off.changeover, 3600) || !eq(on.changeover, 3600) {
		t.Errorf("changeover_time must be 3600 in BOTH modes (report intact): off=%v on=%v", off.changeover, on.changeover)
	}
	if !eq(off.running, on.running) {
		t.Errorf("running_time must be flag-invariant: off=%v on=%v", off.running, on.running)
	}
	if !eq(off.planned-on.planned, on.changeover) || !eq(on.available-off.available, on.changeover) {
		t.Errorf("the planned→available shift must equal changeover_time (%v): Δplanned=%v Δavailable=%v",
			on.changeover, off.planned-on.planned, on.available-off.available)
	}
}
