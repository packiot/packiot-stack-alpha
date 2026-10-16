//go:build golden

package rollup

import (
	"context"
	"math"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// TestGoldenAvailabilityExclusions — line 900 (lead 901) in one hour H:
//
//	lead 901: status 20 (no data) H+10..H+30, then running ; line 900 window H+40..H+50 out of service
//	writers left: available 3600, running 1200, stopped = downtime 2400, ideal_production 6000
//	→ oos 600, no_data 1200, excl 1800: available 1800, stopped 600, downtime 600, ideal 3000
//
// and: a second pass changes nothing (idempotent — no double subtraction); a
// planned event inside the window is not excluded twice; deleting the window
// restores available from the base (total − planned − remaining exclusions).
func TestGoldenAvailabilityExclusions(t *testing.T) {
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
	ddl := `
		DROP SCHEMA IF EXISTS golden CASCADE;
		CREATE SCHEMA golden;
		CREATE TABLE golden.equipments (id_equipment int PRIMARY KEY, tp_equipment int, lead_machine int, id_parentequipment int);
		CREATE TABLE golden.equipment_events (id_equipment int, ts_event timestamptz, ts_end timestamptz, status int, planned_downtime boolean);
		CREATE TABLE golden.equipment_out_of_service (id bigserial, id_enterprise int, id_equipment bigint, period tstzrange, reason text);
		CREATE TABLE golden.equipment_oee_hourly (
		    id_equipment int, ts_value timestamptz, available_time integer, running_time integer,
		    stopped_time integer, downtime integer, planned_downtime integer, ideal_production double precision,
		    no_data_time integer NOT NULL DEFAULT 0, out_of_service_time integer NOT NULL DEFAULT 0);
		INSERT INTO golden.equipments VALUES (900, 3, 901, NULL), (901, 1, NULL, 900);`
	if _, err := pool.Exec(ctx, ddl); err != nil {
		t.Fatalf("ddl: %v", err)
	}
	var h time.Time
	if err := pool.QueryRow(ctx, `SELECT date_trunc('hour', now()) - interval '3 hours'`).Scan(&h); err != nil {
		t.Fatal(err)
	}
	at := func(min int) time.Time { return h.Add(time.Duration(min) * time.Minute) }
	seed := func() {
		for _, st := range []struct {
			sql  string
			args []any
		}{
			{`TRUNCATE golden.equipment_events, golden.equipment_out_of_service, golden.equipment_oee_hourly`, nil},
			{`INSERT INTO golden.equipment_events VALUES (901, $1, NULL, 6, NULL), (901, $2, NULL, 20, NULL), (901, $3, NULL, 6, NULL)`,
				[]any{at(-30), at(10), at(30)}},
			{`INSERT INTO golden.equipment_out_of_service (id_enterprise, id_equipment, period, reason) VALUES (5, 900, tstzrange($1, $2), 'test')`,
				[]any{at(40), at(50)}},
			{`INSERT INTO golden.equipment_oee_hourly (id_equipment, ts_value, available_time, running_time, stopped_time, downtime, planned_downtime, ideal_production)
			  VALUES (900, $1, 3600, 1200, 2400, 2400, 0, 6000)`, []any{h}},
		} {
			if _, err := pool.Exec(ctx, st.sql, st.args...); err != nil {
				t.Fatalf("seed %q: %v", st.sql, err)
			}
		}
	}
	d := flows.Dest{EvSchema: "golden", RefSchema: "golden", SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden", ConfigSchema: "golden"}
	run := func() {
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, `CREATE TEMP TABLE hour_elig ON COMMIT DROP AS SELECT 900 AS id_equipment, $1::timestamptz AS ts_value, false AS target_customized`, h); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, fmtRD(hourExclusionsSQL, d, d.ConfigSchema)); err != nil {
			t.Fatalf("exclusions: %v", err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	type row struct {
		avail, running, stopped, down, nd, oos int
		ideal                                  float64
	}
	get := func() row {
		var r row
		if err := pool.QueryRow(ctx, `SELECT available_time, running_time, stopped_time, downtime, no_data_time, out_of_service_time, ideal_production
		                                 FROM golden.equipment_oee_hourly WHERE id_equipment = 900`).
			Scan(&r.avail, &r.running, &r.stopped, &r.down, &r.nd, &r.oos, &r.ideal); err != nil {
			t.Fatal(err)
		}
		return r
	}
	want := row{avail: 1800, running: 1200, stopped: 600, down: 600, nd: 1200, oos: 600, ideal: 3000}
	check := func(label string, got, w row) {
		t.Helper()
		if got.avail != w.avail || got.running != w.running || got.stopped != w.stopped || got.down != w.down ||
			got.nd != w.nd || got.oos != w.oos || math.Abs(got.ideal-w.ideal) > 1e-6 {
			t.Fatalf("%s: got %+v, want %+v", label, got, w)
		}
	}

	seed()
	run()
	check("first pass", get(), want)
	run() // a tick where no writer rewrote the row: must not subtract again
	check("second pass (idempotent)", get(), want)

	// A planned event H+40..H+45 on the line: that time is already planned
	// (outside available) — the window only excludes the other 300 s.
	seed()
	if _, err := pool.Exec(ctx, `UPDATE golden.equipment_oee_hourly SET available_time = 3300, planned_downtime = 300, ideal_production = 5500`); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO golden.equipment_events VALUES (900, $1, $2, 10, true)`, at(40), at(45)); err != nil {
		t.Fatal(err)
	}
	run()
	if g := get(); g.avail != 3600-300-1500 || g.oos != 600 || g.nd != 1200 {
		t.Fatalf("planned overlap: got %+v, want avail %d oos 600 nd 1200", g, 3600-300-1500)
	}

	// Window deleted (CS corrected it): available comes back from the base.
	seed()
	run()
	if _, err := pool.Exec(ctx, `DELETE FROM golden.equipment_out_of_service`); err != nil {
		t.Fatal(err)
	}
	run()
	if g := get(); g.avail != 3600-1200 || g.oos != 0 || g.nd != 1200 {
		t.Fatalf("window removed: got %+v, want avail 2400 oos 0 nd 1200", g)
	}
}

// The live targets render subtracts out-of-service time; the parity render is
// byte-identical to the pre-token statement.
func TestGoldenOosTargetRender(t *testing.T) {
	live := withOosTarget(shiftTargetsSQL, true, shiftOosTargetTerm)
	parity := withOosTarget(shiftTargetsSQL, false, "")
	if !strings.Contains(live, "ev.ts_planned - COALESCE(e.out_of_service_time, 0)") || strings.Contains(parity, "OOS_TARGET") || strings.Contains(parity, "out_of_service") {
		t.Fatalf("live=%q parity=%q", live, parity)
	}
}
