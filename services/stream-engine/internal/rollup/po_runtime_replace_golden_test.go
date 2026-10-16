//go:build golden

// Golden test for PRODT-169 (spec docs/specs/PRODT-157-operator-app.md, RN-14 / AC-15): after a Replace moves
// SOME runtimes of a PO to another PO, the refresh pass (compute.go + recalc.go) must give each PO the produced,
// scrap and downtime of its OWN runtime windows — never its first-start-to-last-end span — with nothing counted
// in both POs and nothing lost.
//
// Why it holds by construction (and what this pins): compute.go computes every runtime row from the values and
// events INSIDE that row's window; recalc.go sets the header to sum(...) over the PO's production_orders_runtime
// rows. Values and events carry no PO id, so a moved row takes its window's numbers with it. A future change
// that reads the header span (ts_start..ts_end) — the bug the Operator view had — fails C2/C3 here: PO 61 keeps
// R1 and R3, so its span still covers R2 and the stop in the gap.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run GoldenPORuntimeReplace
package rollup

import (
	"context"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// Enterprise 4, machine 950 (self-metered, not line-lead). PO 61 has three closed runtimes inside the 48 h tail:
//
//	R1 [-10 h, -9 h)        10 net / 11 gross per minute, a 5-min stop
//	gap [-9 h, -8 h)        a 20-min stop and 999 units — no runtime of PO 61 ran: nobody's
//	R2 [-8 h, -7 h 30 m)    10 / 11 per minute, a 10-min stop
//	R3 [-7 h, -6 h 15 m)    10 / 11 per minute, a 15-min stop
//
// PO 62 is the Replace target (Available, no runtime).
const poReplaceFixture = `
	INSERT INTO golden.equipments (id_equipment,id_site,id_area,id_enterprise,tp_equipment,production_speed)
	VALUES (950,1,1,4,1,10);
	INSERT INTO golden.production_orders (id_production_order,id_enterprise,id_equipment,status,ts_start,ts_end,recalc_needed)
	VALUES (61,4,950,4, date_trunc('minute', now()) - interval '10 hours', date_trunc('minute', now()) - interval '375 minutes', true),
	       (62,4,950,1, NULL, NULL, false);
	INSERT INTO golden.production_orders_runtime (id_production_order_runtime,id_production_order,id_equipment,runtime_timerange,recalc_needed)
	VALUES (611,61,950, tstzrange(date_trunc('minute', now()) - interval '600 minutes', date_trunc('minute', now()) - interval '540 minutes'), true),
	       (612,61,950, tstzrange(date_trunc('minute', now()) - interval '480 minutes', date_trunc('minute', now()) - interval '450 minutes'), true),
	       (613,61,950, tstzrange(date_trunc('minute', now()) - interval '420 minutes', date_trunc('minute', now()) - interval '375 minutes'), true);
	INSERT INTO golden.equipment_values (id_equipment, ts_value, gross_production_incr, net_production_incr)
	SELECT 950, date_trunc('minute', now()) - make_interval(mins => m), 11, 10
	  FROM generate_series(1, 600) m
	 WHERE m BETWEEN 541 AND 600 OR m BETWEEN 451 AND 480 OR m BETWEEN 376 AND 420
	UNION ALL
	SELECT 950, date_trunc('minute', now()) - interval '510 minutes', 999, 999;
	INSERT INTO golden.equipment_events (id_equipment, ts_event, ts_end, status) VALUES
	  (950, date_trunc('minute', now()) - interval '590 minutes', date_trunc('minute', now()) - interval '585 minutes', 10),
	  (950, date_trunc('minute', now()) - interval '530 minutes', date_trunc('minute', now()) - interval '510 minutes', 10),
	  (950, date_trunc('minute', now()) - interval '470 minutes', date_trunc('minute', now()) - interval '460 minutes', 10),
	  (950, date_trunc('minute', now()) - interval '410 minutes', date_trunc('minute', now()) - interval '395 minutes', 10);`

func TestGoldenPORuntimeReplaceOwnWindows(t *testing.T) {
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
	for _, s := range []string{poRuntimeSchema, poReplaceFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden",
		SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden"}
	window, excl := "1 month", []int{6}
	pass := func() {
		t.Helper()
		if _, err := RunPropagateHeaders(ctx, d, window, excl); err != nil {
			t.Fatal(err)
		}
		if _, err := RunCompute(ctx, d, window, false, false, LineLeadScope{Enterprises: []int{3}}); err != nil {
			t.Fatal(err)
		}
		if _, err := RunRecalc(ctx, d, window, excl); err != nil {
			t.Fatal(err)
		}
	}

	type totals struct{ net, gross, stopped float64 }
	header := func(po int) totals {
		t.Helper()
		var x totals
		if err := pool.QueryRow(ctx, `
			SELECT COALESCE(net_production,-1), COALESCE(gross_production,-1), COALESCE(stopped_time,-1)
			  FROM golden.production_orders WHERE id_production_order = $1`, po).Scan(&x.net, &x.gross, &x.stopped); err != nil {
			t.Fatal(err)
		}
		return x
	}
	eq := func(a, b totals) bool {
		return math.Abs(a.net-b.net) < 1e-9 && math.Abs(a.gross-b.gross) < 1e-9 && math.Abs(a.stopped-b.stopped) < 1e-9
	}

	// C1: before the Replace PO 61 owns R1+R2+R3 — 135 minutes → net 1350, gross 1485, stops 5+10+15 min.
	// The gap's 999 units and its 20-min stop belong to no runtime and are counted nowhere.
	pass()
	if got, want := header(61), (totals{1350, 1485, 1800}); !eq(got, want) {
		t.Fatalf("C1 PO 61 before replace = %+v, want %+v", got, want)
	}

	// The Replace as edge-api writes it (PRODT-169): R2 moves to PO 62, both headers and the row are re-flagged.
	if _, err := pool.Exec(ctx, `
		UPDATE golden.production_orders_runtime SET id_production_order = 62, recalc_needed = true
		 WHERE id_production_order_runtime = 612;
		UPDATE golden.production_orders SET status = 4, recalc_needed = true,
		       ts_start = date_trunc('minute', now()) - interval '480 minutes',
		       ts_end = date_trunc('minute', now()) - interval '450 minutes'
		 WHERE id_production_order = 62;
		UPDATE golden.production_orders SET recalc_needed = true WHERE id_production_order = 61;`); err != nil {
		t.Fatal(err)
	}
	pass()

	// C2: PO 61 = R1 + R3 (105 min, stops 5 + 15 min) although its span still covers R2 and the gap.
	if got, want := header(61), (totals{1050, 1155, 1200}); !eq(got, want) {
		t.Errorf("C2 PO 61 after replace = %+v, want %+v (R1+R3 only)", got, want)
	}
	// C3: PO 62 = R2 (30 min, a 10-min stop).
	if got, want := header(62), (totals{300, 330, 600}); !eq(got, want) {
		t.Errorf("C3 PO 62 after replace = %+v, want %+v (R2)", got, want)
	}
	// C4: conserved — nothing counted in both POs, nothing lost.
	a, b := header(61), header(62)
	if sum := (totals{a.net + b.net, a.gross + b.gross, a.stopped + b.stopped}); !eq(sum, totals{1350, 1485, 1800}) {
		t.Errorf("C4 PO 61 + PO 62 = %+v, want the pre-replace total {1350 1485 1800}", sum)
	}
}
