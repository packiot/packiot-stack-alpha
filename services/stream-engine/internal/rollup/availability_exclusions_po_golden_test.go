//go:build golden

package rollup

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// TestGoldenPOExclusions — a closed 2 h PO on line 900 (lead 901):
//
//	planned event on the line H+90..H+100 (600 s) ; lead status 20 H+10..H+30 (1200 s)
//	out-of-service window on the line H+60..H+70 (600 s)
//	→ available = 7200 − 600 − 1800 = 4800, no_data 1200, out_of_service 600
//
// A second pass gives the same row (recomputed from the span, not decremented),
// and the flag-off render is the exact pre-exclusion statement.
func TestGoldenPOExclusions(t *testing.T) {
	off := withPOExclusions(computeAvailabilitySQL, false, "golden")
	if strings.Contains(off, "/*EXCL") || strings.Contains(off, "excl") {
		t.Fatalf("flag-off render must be the pre-exclusion statement")
	}
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
	for _, s := range []string{
		`DROP SCHEMA IF EXISTS golden CASCADE`,
		`CREATE SCHEMA golden`,
		`CREATE TABLE golden.equipments (id_equipment int PRIMARY KEY, id_site int, lead_machine int, gross_machine int, id_parentequipment int)`,
		`CREATE TABLE golden.equipment_events (id_equipment int, ts_event timestamptz, ts_end timestamptz, status int, planned_downtime boolean, change_over boolean)`,
		`CREATE TABLE golden.equipment_out_of_service (id bigserial, id_enterprise int, id_equipment bigint, period tstzrange, reason text)`,
		`CREATE TABLE golden.production_orders_runtime (id_equipment int, runtime_timerange tstzrange, recalc_needed boolean,
		    available_time int, planned_downtime int, no_data_time int NOT NULL DEFAULT 0, out_of_service_time int NOT NULL DEFAULT 0)`,
		`INSERT INTO golden.equipments VALUES (900, 1, 901, NULL, NULL), (901, 1, NULL, NULL, 900)`,
	} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	var h time.Time
	if err := pool.QueryRow(ctx, `SELECT date_trunc('hour', now()) - interval '5 hours'`).Scan(&h); err != nil {
		t.Fatal(err)
	}
	at := func(m int) time.Time { return h.Add(time.Duration(m) * time.Minute) }
	for _, st := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO golden.production_orders_runtime (id_equipment, runtime_timerange, recalc_needed) VALUES (900, tstzrange($1, $2), true)`, []any{at(0), at(120)}},
		// Closed events (the stale-open closer sets ts_end): the PO planned sum ends an
		// event at ts_end, else now() — not at the next event like the hour/shift grains.
		{`INSERT INTO golden.equipment_events VALUES (900, $1, $2, 6, NULL, NULL), (900, $2, $3, 10, true, NULL), (900, $3, NULL, 6, NULL, NULL)`, []any{at(0), at(90), at(100)}},
		{`INSERT INTO golden.equipment_events VALUES (901, $1, NULL, 6, NULL, NULL), (901, $2, NULL, 20, NULL, NULL), (901, $3, NULL, 6, NULL, NULL)`, []any{at(0), at(10), at(30)}},
		{`INSERT INTO golden.equipment_out_of_service (id_enterprise, id_equipment, period, reason) VALUES (5, 900, tstzrange($1, $2), 'test')`, []any{at(60), at(70)}},
	} {
		if _, err := pool.Exec(ctx, st.sql, st.args...); err != nil {
			t.Fatalf("%s: %v", st.sql, err)
		}
	}
	d := flows.Dest{EvSchema: "golden", RefSchema: "golden", SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden", ConfigSchema: "golden"}
	stmt := fmtRD(withPOExclusions(computeAvailabilitySQL, true, d.ConfigSchema), d, plannedDowntimeExpr(false))
	for pass := 1; pass <= 2; pass++ {
		if _, err := pool.Exec(ctx, stmt, "1 day"); err != nil {
			t.Fatalf("pass %d: %v", pass, err)
		}
		var avail, planned, nd, oos int
		if err := pool.QueryRow(ctx, `SELECT available_time, planned_downtime, no_data_time, out_of_service_time FROM golden.production_orders_runtime`).
			Scan(&avail, &planned, &nd, &oos); err != nil {
			t.Fatal(err)
		}
		if avail != 4800 || planned != 600 || nd != 1200 || oos != 600 {
			t.Fatalf("pass %d: available %d planned %d no_data %d oos %d; want 4800/600/1200/600", pass, avail, planned, nd, oos)
		}
	}
}
