//go:build golden

// Golden-fixture test for the LINE-FROM-LEAD derivation (line_lead.go). Proves
// that a tp=3 LINE with NO counter stream of its own borrows its designated
// lead_machine's aggregates wholesale: gross/net from the lead's 1hour cagg,
// Availability from idle-timeout sessionization of the lead's productive
// minutes (an idle gap drives it below 1), ideal_speed from the lead's
// production_speed, and the OEE waterfall back-solved off those.
//
// shiftLineLeadSQL is exercised in ISOLATION (via ShiftLineLeadSQLForParity)
// against a controlled shift_elig temp table so the assertions are exact and
// independent of the live eligibility window. Reuses goldenSchema for the
// enterprise/equipments DDL, adding lead_machine (the line-metered column) plus
// the shift + cagg tables the pass reads/writes.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run LineLead
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

func TestGoldenLineLead(t *testing.T) {
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

	// DDL: goldenSchema (enterprise/equipments) + lead_machine column + the
	// shift-grain + cagg tables the line-lead pass reads and writes.
	const lineLeadSchema = `
		ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS lead_machine int;
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
		    target double precision, proportional_target double precision,
		    computed_at timestamptz, source_watermark timestamptz
		);
		CREATE TABLE golden.ca_agg_equipment_values_1hour (
		    id_equipment int, ts_value timestamptz, ts_value_production timestamptz,
		    id_shift int, state int, speed double precision, ideal_production_speed double precision,
		    gross_production_incr double precision, net_production_incr double precision
		);
		CREATE TABLE golden.ca_agg_equipment_values_1min (LIKE golden.ca_agg_equipment_values_1hour INCLUDING ALL);
		SET search_path TO golden, public;`
	for _, s := range []string{goldenSchema, lineLeadSchema} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("ddl: %v", err)
		}
	}

	// Fixture: enterprise 3, one tp=3 LINE (900) whose lead_machine is the tp=1
	// MACHINE (901, production_speed 100). The line has NO cagg of its own; the
	// lead does. The bucket is a complete hour 3h in the past (ts_total = 3600).
	//   lead 901 1hour cagg: gross 1000 / net 950 → line oee_q = 0.95.
	//   lead 901 1min productive minutes: 0-9 and 40-59 (a 31-min gap ≫ the
	//     300s idle timeout → the gap is stopped). Expected running = session A
	//     [0m .. 9m+300s→14m] = 840s + session B [40m .. min(59m+300s,60m)=60m]
	//     = 1200s → 2040s → Availability 0.5667 (< 1, idle penalty).
	const fixture = `
		INSERT INTO golden.equipments (id_equipment,id_site,id_area,id_enterprise,tp_equipment,production_speed,lead_machine)
		VALUES (900,1,1,3,3,NULL,901),   -- the LINE (no rated speed of its own)
		       (901,1,1,3,1,100,NULL);   -- its lead MACHINE (rated speed 100)
		-- controlled eligibility set: one shift bucket for the line, a complete
		-- hour 3h old (ts_total = 3600, within the 25-day update guard).
		CREATE TEMP TABLE shift_elig (id_equipment int, ts_value timestamptz, ts_end timestamptz);
		INSERT INTO shift_elig
		SELECT 900, date_trunc('hour', now()) - interval '3 hours',
		            date_trunc('hour', now()) - interval '2 hours';
		INSERT INTO golden.equipment_runtime_shift
		    (id_equipment, ts_value, ts_end, ts_value_production, id_shift, recalc_needed, ideal_speed)
		VALUES (900, date_trunc('hour', now()) - interval '3 hours',
		             date_trunc('hour', now()) - interval '2 hours',
		             date_trunc('day', now()), 1, true, 0);
		-- lead's 1hour cagg (gross/net for the line)
		INSERT INTO golden.ca_agg_equipment_values_1hour
		    (id_equipment, ts_value, gross_production_incr, net_production_incr)
		VALUES (901, date_trunc('hour', now()) - interval '3 hours', 1000, 950);
		-- lead's 1min productive minutes: 0-9 and 40-59 (idle gap between)
		INSERT INTO golden.ca_agg_equipment_values_1min (id_equipment, ts_value, gross_production_incr)
		SELECT 901, date_trunc('hour', now()) - interval '3 hours' + make_interval(mins => m), 10
		  FROM generate_series(0,9) m
		UNION ALL
		SELECT 901, date_trunc('hour', now()) - interval '3 hours' + make_interval(mins => m), 10
		  FROM generate_series(40,59) m;`

	// TEMP tables are connection-scoped; acquire ONE conn for fixture + pass.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SET search_path TO golden, public`); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, fixture); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	// The line-lead pass, verbatim from line_lead.go (single source): enterprise
	// 3 opted in, 300s idle timeout. %[1]s=EvSchema, %[2]s=RefSchema.
	stmt := fmt.Sprintf(ShiftLineLeadSQLForParity(), "golden", "golden", pgIntArrayLiteral([]int{3}), 300)
	if _, err := conn.Exec(ctx, stmt); err != nil {
		t.Fatalf("line-lead: %v", err)
	}

	var r struct {
		gross, net, avail, running, stopped, ideal, oee, oeeA, oeeP, oeeQ float64
		recalc                                                            bool
	}
	if err := conn.QueryRow(ctx,
		`SELECT gross, net, available_time, running_time, stopped_time, ideal_speed,
		        oee, oee_a, oee_p, oee_q, recalc_needed
		   FROM golden.equipment_runtime_shift WHERE id_equipment = 900`).
		Scan(&r.gross, &r.net, &r.avail, &r.running, &r.stopped, &r.ideal,
			&r.oee, &r.oeeA, &r.oeeP, &r.oeeQ, &r.recalc); err != nil {
		t.Fatal(err)
	}
	approx := func(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

	// HEADLINE: the line borrowed the lead's counts and derived availability.
	if !approx(r.gross, 1000) || !approx(r.net, 950) {
		t.Errorf("line gross/net = %v/%v, want 1000/950 (from lead's 1hour cagg)", r.gross, r.net)
	}
	if !approx(r.ideal, 100) {
		t.Errorf("line ideal_speed = %v, want 100 (lead's production_speed)", r.ideal)
	}
	if !approx(r.avail, 3600) {
		t.Errorf("line available_time = %v, want 3600 (full bucket, no planned downtime)", r.avail)
	}
	if !approx(r.running, 2040) {
		t.Errorf("line running_time = %v, want 2040 (session A 840 + session B 1200 from lead's minutes)", r.running)
	}
	if !approx(r.stopped, 1560) {
		t.Errorf("line stopped_time = %v, want 1560 (the idle gap)", r.stopped)
	}
	if !(r.oeeA > 0 && r.oeeA < 1.0) {
		t.Errorf("line oee_a = %v, MUST be in (0,1) (running derived from lead, availability < 1 due to gap)", r.oeeA)
	}
	if !approx(r.oeeA, 2040.0/3600.0) {
		t.Errorf("line oee_a = %v, want %v", r.oeeA, 2040.0/3600.0)
	}
	if !approx(r.oeeQ, 0.95) {
		t.Errorf("line oee_q = %v, want 0.95 (net 950 / gross 1000)", r.oeeQ)
	}
	if !(r.oee > 0) {
		t.Errorf("line oee = %v, MUST be > 0 (net / ideal_production)", r.oee)
	}
	if !approx(r.oee, 950.0/((3600.0/60.0)*100.0)) {
		t.Errorf("line oee = %v, want %v", r.oee, 950.0/((3600.0/60.0)*100.0))
	}
	// Shift back-solves oee_p inline so the waterfall closes oee = a·p·q.
	if math.Abs(r.oee-r.oeeA*r.oeeP*r.oeeQ) > 1e-6 {
		t.Errorf("OEE waterfall broken: oee=%v but a*p*q=%v (a=%v p=%v q=%v)", r.oee, r.oeeA*r.oeeP*r.oeeQ, r.oeeA, r.oeeP, r.oeeQ)
	}
	if r.recalc {
		t.Error("line recalc_needed must be cleared by the pass")
	}
}
