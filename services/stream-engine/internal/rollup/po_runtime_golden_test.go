//go:build golden

// Golden test for the PO-runtime refresh pass (compute.go + recalc.go) as
// LoopRefresh runs it: header propagation → compute → recalc → closed-row sweep.
//
// The regression it pins (2026-09-29 CPACK audit): a CLOSED PO's runtime row is
// only recomputed while open or for 48 h after it closed, and its header only for
// 48 h after it STARTED. A runtime row computed wrong (older code, data that arrived
// late, a repair script) therefore stayed wrong forever — SLEEVE1 PO 896953 kept
// net 0 for a 9-day run whose line hourly (and legacy) read ~763 k.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run GoldenPORuntime
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

const poRuntimeSchema = `
	DROP SCHEMA IF EXISTS golden CASCADE;
	CREATE SCHEMA golden;
	CREATE TABLE golden.equipments (
	    id_equipment int PRIMARY KEY, id_site int, id_area int, id_enterprise int,
	    tp_equipment int, production_speed double precision, lead_machine int,
	    gross_machine int, net_machine int, gross_counter text, net_counter text,
	    scrap_machine int
	);
	CREATE TABLE golden.production_orders (
	    id_production_order bigint PRIMARY KEY, id_enterprise int NOT NULL,
	    id_equipment int NOT NULL, status int NOT NULL,
	    ts_start timestamptz, ts_end timestamptz,
	    recalc_needed boolean NOT NULL DEFAULT false,
	    gross_production double precision, net_production double precision,
	    oee double precision, oee_q double precision, oee_a double precision,
	    oee_p double precision, speed double precision,
	    available_time double precision, running_time double precision,
	    stopped_time double precision, planned_downtime double precision,
	    ideal_production_speed double precision, last_update timestamptz
	);
	CREATE TABLE golden.production_orders_runtime (
	    id_production_order_runtime bigserial PRIMARY KEY,
	    id_production_order bigint NOT NULL, id_equipment int NOT NULL,
	    runtime_timerange tstzrange NOT NULL, recalc_needed boolean DEFAULT false,
	    gross_production double precision, net_production double precision,
	    oee_q double precision, speed double precision,
	    running_time double precision, stopped_time double precision,
	    available_time double precision, planned_downtime double precision
	);
	CREATE TABLE golden.equipment_values (
	    id_equipment int, ts_value timestamptz, gross_production_incr double precision,
	    net_production_incr double precision, speed double precision
	);
	CREATE TABLE golden.equipment_events (
	    id_equipment int, ts_event timestamptz, ts_end timestamptz, status int,
	    planned_downtime boolean, change_over boolean
	);
	CREATE TABLE golden.equipment_categorical_1min (
	    id_equipment int, ts_value timestamptz, gross_production_incr double precision,
	    net_production_incr double precision, scrap_incr double precision
	);`

// Fixture, enterprise 3 (line-lead). LINE 900 (tp=3) is NET-ONLY: its lead 901
// reports only the processed counter (CPACK SLEEVE/CER400/ISIMAT).
//
//	PO 1 — closed 5 days ago (outside every 48 h tail). Runtime row holds the
//	       stale 0/0 of the old code, flag cleared; header 0/0, flag cleared.
//	       The lead counted 10/min for the run's 60 minutes → the right answer is
//	       net 600 (gross 600 by identity).
//	PO 2 — closed 4 days ago, already correct (runtime + header 300/300): the
//	       sweep must recompute it to the SAME numbers (healthy rows unchanged).
//	PO 3 — ran 3 days, closed 1 hour ago: runtime row already recomputed after the
//	       close (500), header still carries the last running-pass sum (100). Only
//	       an end-keyed header tail re-sums it.
//	PO 9 — enterprise 6 (excluded from recalc): propagation must never flag it.
const poRuntimeFixture = `
	INSERT INTO golden.equipments (id_equipment,id_site,id_area,id_enterprise,tp_equipment,production_speed,lead_machine)
	VALUES (900,1,1,3,3,10,901), (901,1,1,3,1,10,NULL), (910,1,1,6,3,10,NULL);
	INSERT INTO golden.production_orders (id_production_order,id_enterprise,id_equipment,status,ts_start,ts_end,recalc_needed,gross_production,net_production)
	VALUES (1,3,900,3, date_trunc('minute', now()) - interval '6 days', date_trunc('minute', now()) - interval '6 days' + interval '60 minutes', false, 0, 0),
	       (2,3,900,3, date_trunc('minute', now()) - interval '4 days', date_trunc('minute', now()) - interval '4 days' + interval '30 minutes', false, 300, 300),
	       (3,3,900,3, date_trunc('minute', now()) - interval '3 days', date_trunc('minute', now()) - interval '1 hour', false, 100, 100),
	       (9,6,910,3, date_trunc('minute', now()) - interval '3 days', date_trunc('minute', now()) - interval '3 days' + interval '1 hour', false, 7, 7);
	INSERT INTO golden.production_orders_runtime (id_production_order,id_equipment,runtime_timerange,recalc_needed,gross_production,net_production)
	VALUES (1,900, tstzrange(date_trunc('minute', now()) - interval '6 days', date_trunc('minute', now()) - interval '6 days' + interval '60 minutes'), false, 0, 0),
	       (2,900, tstzrange(date_trunc('minute', now()) - interval '4 days', date_trunc('minute', now()) - interval '4 days' + interval '30 minutes'), false, 300, 300),
	       (3,900, tstzrange(date_trunc('minute', now()) - interval '3 days', date_trunc('minute', now()) - interval '1 hour'), false, 500, 500),
	       (9,910, tstzrange(date_trunc('minute', now()) - interval '3 days', date_trunc('minute', now()) - interval '3 days' + interval '1 hour'), true, 7, 7);
	-- lead 901: net-only, 10/min over PO 1's 60 minutes, PO 2's 30 minutes and 50
	-- minutes of PO 3's run.
	INSERT INTO golden.equipment_categorical_1min (id_equipment, ts_value, net_production_incr)
	SELECT 901, date_trunc('minute', now()) - interval '6 days' + make_interval(mins => m), 10 FROM generate_series(0,59) m
	UNION ALL
	SELECT 901, date_trunc('minute', now()) - interval '4 days' + make_interval(mins => m), 10 FROM generate_series(0,29) m
	UNION ALL
	SELECT 901, date_trunc('minute', now()) - interval '2 days' + make_interval(mins => m), 10 FROM generate_series(0,49) m;`

func TestGoldenPORuntimeClosedRowRecompute(t *testing.T) {
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
	for _, s := range []string{poRuntimeSchema, poRuntimeFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden",
		SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden"}
	window, excl, ll := "1 month", []int{6}, []int{3}

	// One LoopRefresh pass, in its order. The sweep here covers every row (one
	// slice): it flags for the NEXT pass.
	pass := func(sweepSlices []int64) {
		t.Helper()
		if _, err := RunPropagateHeaders(ctx, d, window, excl); err != nil {
			t.Fatal(err)
		}
		if _, err := RunCompute(ctx, d, window, false, LineLeadScope{Enterprises: ll}); err != nil {
			t.Fatal(err)
		}
		if _, err := RunRecalc(ctx, d, window, excl); err != nil {
			t.Fatal(err)
		}
		if _, err := RunSweep(ctx, d, window, 1, sweepSlices); err != nil {
			t.Fatal(err)
		}
	}
	pass([]int64{0})
	pass(nil)

	type pair struct{ rtNet, rtGross, hdNet, hdGross float64 }
	get := func(id int) pair {
		var p pair
		if err := pool.QueryRow(ctx, `
			SELECT COALESCE(r.net_production,-1), COALESCE(r.gross_production,-1),
			       COALESCE(p.net_production,-1), COALESCE(p.gross_production,-1)
			  FROM golden.production_orders p JOIN golden.production_orders_runtime r USING (id_production_order)
			 WHERE p.id_production_order = $1`, id).Scan(&p.rtNet, &p.rtGross, &p.hdNet, &p.hdGross); err != nil {
			t.Fatal(err)
		}
		return p
	}
	eq := func(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

	// PO 1: the stale closed row is recomputed from the lead (net-only ⇒ gross = net)
	// and the header re-summed from it.
	if p := get(1); !eq(p.rtNet, 600) || !eq(p.rtGross, 600) || !eq(p.hdNet, 600) || !eq(p.hdGross, 600) {
		t.Errorf("PO1 closed-row recompute: %+v, want runtime+header 600/600", p)
	}
	// PO 2: healthy closed row recomputed to the same numbers.
	if p := get(2); !eq(p.rtNet, 300) || !eq(p.hdNet, 300) {
		t.Errorf("PO2 healthy row changed: %+v, want 300", p)
	}
	// PO 3: header re-summed after a long run closed (end-keyed 48 h tail).
	if p := get(3); !eq(p.hdNet, 500) {
		t.Errorf("PO3 header after close: %+v, want header net 500", p)
	}
	// PO 9: excluded enterprise — header never flagged/touched.
	var rc bool
	var net float64
	if err := pool.QueryRow(ctx, `SELECT recalc_needed, net_production FROM golden.production_orders WHERE id_production_order=9`).Scan(&rc, &net); err != nil {
		t.Fatal(err)
	}
	if rc || !eq(net, 7) {
		t.Errorf("PO9 excluded enterprise touched: recalc=%v net=%v", rc, net)
	}
}

// TestGoldenPORuntimeHeaderTailAfterLongRun isolates recalc.go's header tail: a PO
// that ran longer than 48 h and just closed must be re-summed (prod keyed the tail
// on ts_start and never re-summed it).
func TestGoldenPORuntimeHeaderTailAfterLongRun(t *testing.T) {
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
	for _, s := range []string{poRuntimeSchema, poRuntimeFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden",
		SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden"}
	// recalc twice: the first pass re-flags (tail), the second re-sums.
	for i := 0; i < 2; i++ {
		if _, err := RunRecalc(ctx, d, "1 month", []int{6}); err != nil {
			t.Fatal(err)
		}
	}
	var net float64
	if err := pool.QueryRow(ctx, `SELECT net_production FROM golden.production_orders WHERE id_production_order=3`).Scan(&net); err != nil {
		t.Fatal(err)
	}
	if math.Abs(net-500) > 1e-9 {
		t.Errorf("PO3 header net = %v, want 500 (long run closed 1 h ago must be re-summed)", net)
	}
}

// TestGoldenPORuntimeReconcilesPerHour pins the reconcile GRAIN of the line-lead PO
// pass. Line 920 meters gross at the infeed (921, 10/min every minute) and net at
// the outfeed (922, 20 every OTHER minute — an outfeed that reports every 2 min):
// 600 in, 600 out over the hour. Reconciled per MINUTE, every odd minute read "net
// meter missing" and filled net = gross, so net came out 900 (+50 pct) — the
// 5-13 pct inflation a no-clamp recompute showed on CPACK L3/L4/L6. Per hour: 600/600.
func TestGoldenPORuntimeReconcilesPerHour(t *testing.T) {
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
	const fixture = `
		INSERT INTO golden.equipments (id_equipment,id_site,id_area,id_enterprise,tp_equipment,production_speed,lead_machine,gross_machine,net_machine)
		VALUES (920,1,1,3,3,10,921,921,922), (921,1,1,3,1,10,NULL,NULL,NULL), (922,1,1,3,1,10,NULL,NULL,NULL);
		INSERT INTO golden.production_orders (id_production_order,id_enterprise,id_equipment,status,ts_start,ts_end,recalc_needed)
		VALUES (20,3,920,3, date_trunc('hour', now()) - interval '3 hours', date_trunc('hour', now()) - interval '2 hours', true);
		INSERT INTO golden.production_orders_runtime (id_production_order,id_equipment,runtime_timerange,recalc_needed)
		VALUES (20,920, tstzrange(date_trunc('hour', now()) - interval '3 hours', date_trunc('hour', now()) - interval '2 hours'), true);
		INSERT INTO golden.equipment_categorical_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 921, date_trunc('hour', now()) - interval '3 hours' + make_interval(mins => m), 10 FROM generate_series(0,59) m;
		INSERT INTO golden.equipment_categorical_1min (id_equipment, ts_value, net_production_incr)
		SELECT 922, date_trunc('hour', now()) - interval '3 hours' + make_interval(mins => m), 20 FROM generate_series(1,59,2) m;`
	for _, s := range []string{poRuntimeSchema, fixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden",
		SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden"}
	if _, err := RunCompute(ctx, d, "1 month", false, LineLeadScope{Enterprises: []int{3}}); err != nil {
		t.Fatal(err)
	}
	var gross, net float64
	if err := pool.QueryRow(ctx, `SELECT gross_production, net_production FROM golden.production_orders_runtime WHERE id_production_order = 20`).Scan(&gross, &net); err != nil {
		t.Fatal(err)
	}
	if math.Abs(gross-600) > 1e-9 || math.Abs(net-600) > 1e-9 {
		t.Errorf("PO 20 gross/net = %v/%v, want 600/600 (per-hour reconcile; per-minute gives net 900)", gross, net)
	}
}

// TestGoldenPORuntimeFlagMidPassIsNotLost pins the ONE-SNAPSHOT rule of RunCompute
// (2026-09-30). PO 31's runtime row is flagged by ANOTHER connection between the
// line-lead phase (A2) and the phase that clears flags (A) — what a repair script or
// the replicator does when its commit lands mid-pass. As separate autocommit
// statements, A saw the new flag and cleared it without A2's values: the row ended
// flag=false, gross/net NULL, and nothing would ever recompute it (closed > 48 h ago,
// outside every re-flag tail). In one REPEATABLE READ snapshot the row keeps its flag
// and the next pass computes it (600/600).
func TestGoldenPORuntimeFlagMidPassIsNotLost(t *testing.T) {
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
	const fixture = `
		INSERT INTO golden.equipments (id_equipment,id_site,id_area,id_enterprise,tp_equipment,production_speed,lead_machine,gross_machine,net_machine)
		VALUES (930,1,1,3,3,10,931,931,931), (931,1,1,3,1,10,NULL,NULL,NULL);
		-- PO 30: flagged, closed 3 days ago; PO 31: NOT flagged yet, closed 4 days ago.
		INSERT INTO golden.production_orders (id_production_order,id_enterprise,id_equipment,status,ts_start,ts_end,recalc_needed) VALUES
		  (30,3,930,3, date_trunc('hour', now()) - interval '3 days 1 hour', date_trunc('hour', now()) - interval '3 days', true),
		  (31,3,930,3, date_trunc('hour', now()) - interval '4 days 1 hour', date_trunc('hour', now()) - interval '4 days', false);
		INSERT INTO golden.production_orders_runtime (id_production_order,id_equipment,runtime_timerange,recalc_needed) VALUES
		  (30,930, tstzrange(date_trunc('hour', now()) - interval '3 days 1 hour', date_trunc('hour', now()) - interval '3 days'), true),
		  (31,930, tstzrange(date_trunc('hour', now()) - interval '4 days 1 hour', date_trunc('hour', now()) - interval '4 days'), false);
		INSERT INTO golden.equipment_categorical_1min (id_equipment, ts_value, gross_production_incr, net_production_incr)
		SELECT 931, b + make_interval(mins => m), 10, 10
		  FROM generate_series(0,59) m,
		       (VALUES (date_trunc('hour', now()) - interval '3 days 1 hour'), (date_trunc('hour', now()) - interval '4 days 1 hour')) v(b);`
	for _, s := range []string{poRuntimeSchema, fixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden",
		SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden"}
	scope := LineLeadScope{Enterprises: []int{3}}

	computeBetweenPhasesHook = func(ctx context.Context) {
		// A different pooled connection (RunCompute's tx holds its own): commits at once.
		if _, err := pool.Exec(ctx, `UPDATE golden.production_orders_runtime SET recalc_needed = true WHERE id_production_order = 31`); err != nil {
			t.Errorf("mid-pass flag: %v", err)
		}
	}
	_, err = RunCompute(ctx, d, "1 month", false, scope)
	computeBetweenPhasesHook = nil
	if err != nil {
		t.Fatal(err)
	}
	var flagged bool
	if err := pool.QueryRow(ctx, `SELECT recalc_needed FROM golden.production_orders_runtime WHERE id_production_order = 31`).Scan(&flagged); err != nil {
		t.Fatal(err)
	}
	if !flagged {
		t.Fatalf("PO 31 flag was cleared by the pass that never computed it (lost recompute)")
	}
	if _, err := RunCompute(ctx, d, "1 month", false, scope); err != nil {
		t.Fatal(err)
	}
	for _, po := range []int{30, 31} {
		var gross, net *float64
		if err := pool.QueryRow(ctx, `SELECT gross_production, net_production FROM golden.production_orders_runtime WHERE id_production_order = $1`, po).Scan(&gross, &net); err != nil {
			t.Fatal(err)
		}
		if gross == nil || net == nil || math.Abs(*gross-600) > 1e-9 || math.Abs(*net-600) > 1e-9 {
			t.Errorf("PO %d gross/net = %v/%v, want 600/600", po, gross, net)
		}
	}
}
