//go:build golden

// Golden regression for the EVENT LOOKBACK bug (2026-09-29). Events are open-ended
// state markers — one lasts until the next event starts — but the line-lead
// planned_ev scan and the hour/shift events passes only read events with ts_event
// inside a bounded lookback (batch start − 10 days / now − 10 days / now − 25 days).
// A planned stop that STARTED before that bound and is still in effect was dropped,
// so an idle line read its whole bucket as UNPLANNED downtime (CPACK DUBUIT1/2,
// SLEEVE2). Every case below plants ONE planned event well before the bound and no
// later event: the bucket must be fully planned. On the old SQL each reads 0.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run Lookback
package rollup

import (
	"context"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const lookbackSchema = `
	ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS lead_machine int;
	ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS gross_machine bigint;
	ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS net_machine bigint;
	ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS gross_counter text;
	ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS net_counter text;
	ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS scrap_machine bigint;
	ALTER TABLE golden.equipments ADD COLUMN IF NOT EXISTS fill_missing_meter boolean;
	CREATE TABLE golden.equipment_oee_shift (
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
	CREATE TABLE golden.equipment_oee_hourly (LIKE golden.equipment_oee_shift INCLUDING ALL);
	CREATE TABLE golden.equipment_categorical_1hour (
	    id_equipment int, ts_value timestamptz,
	    gross_production_incr double precision, net_production_incr double precision,
	    scrap_incr double precision
	);
	CREATE TABLE golden.equipment_categorical_1min (LIKE golden.equipment_categorical_1hour INCLUDING ALL);
	-- line 900 (lead 901) for the line-lead passes; line 910 for the plain events passes.
	INSERT INTO golden.equipments (id_equipment,id_site,id_area,id_enterprise,tp_equipment,production_speed,lead_machine)
	VALUES (900,1,1,3,3,NULL,901), (901,1,1,3,1,100,NULL), (910,1,1,4,3,100,NULL);`

func lookbackSetup(t *testing.T) (context.Context, *pgxpool.Pool, func()) {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	for _, s := range []string{goldenSchema, lookbackSchema} {
		if _, err := pool.Exec(ctx, s); err != nil {
			pool.Close()
			cancel()
			t.Fatalf("ddl: %v", err)
		}
	}
	return ctx, pool, func() { pool.Close(); cancel() }
}

func execAll(ctx context.Context, t *testing.T, tx pgx.Tx, stmts ...string) {
	t.Helper()
	for _, s := range stmts {
		if _, err := tx.Exec(ctx, s); err != nil {
			t.Fatalf("exec: %v\n%s", err, s)
		}
	}
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

// Line-lead SHIFT + HOUR passes: planned event 20 days before the bucket (> the
// 10-day planned_ev lookback), no later event → the 1h bucket is 100 pct planned.
func TestGoldenLookbackLineLeadPlanned(t *testing.T) {
	ctx, pool, done := lookbackSetup(t)
	defer done()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	execAll(ctx, t, tx, `SET LOCAL search_path TO golden, public`, `
		CREATE TEMP TABLE shift_elig (id_equipment int, ts_value timestamptz, ts_end timestamptz);
		INSERT INTO shift_elig SELECT 900, date_trunc('hour', now()) - interval '3 hours', date_trunc('hour', now()) - interval '2 hours';
		CREATE TEMP TABLE hour_elig (id_equipment int, ts_value timestamptz);
		INSERT INTO hour_elig SELECT 900, date_trunc('hour', now()) - interval '2 hours';
		INSERT INTO golden.equipment_oee_shift (id_equipment, ts_value, ts_end, recalc_needed, ideal_speed)
		SELECT 900, date_trunc('hour', now()) - interval '3 hours', date_trunc('hour', now()) - interval '2 hours', true, 0;
		INSERT INTO golden.equipment_oee_hourly (id_equipment, ts_value, recalc_needed, ideal_speed)
		SELECT 900, date_trunc('hour', now()) - interval '2 hours', true, 0;
		-- the in-effect planned stop, begun 20 days before the buckets; an OLDER
		-- running event before it proves the LATERAL picks the LATEST pre-bound event.
		INSERT INTO golden.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
		VALUES (900, date_trunc('hour', now()) - interval '21 days', NULL, 6, false, false),
		       (900, date_trunc('hour', now()) - interval '20 days', NULL, 10, true, false);`,
		fmtRP(ShiftLineLeadSQLForParity(), "golden", pgIntArrayLiteral([]int{3}), 300),
		fmtRP(HourLineLeadSQLForParity(), "golden", pgIntArrayLiteral([]int{3}), 300))

	for _, tbl := range []string{"equipment_oee_shift", "equipment_oee_hourly"} {
		var planned, avail float64
		if err := tx.QueryRow(ctx, `SELECT planned_downtime, available_time FROM golden.`+tbl+` WHERE id_equipment = 900`).
			Scan(&planned, &avail); err != nil {
			t.Fatal(err)
		}
		if !near(planned, 3600) || !near(avail, 0) {
			t.Errorf("%s line-lead: planned_downtime=%v available_time=%v, want 3600/0 (planned stop begun 20 days earlier is still in effect; old SQL dropped it → 0/3600)", tbl, planned, avail)
		}
	}
}

// Plain (state-driven) HOUR and SHIFT events passes: same class. The hour pass
// scans now()−10 days, the shift pass now()−25 days; the planned event sits 30
// days back with nothing after it.
func TestGoldenLookbackEventsPassesPlanned(t *testing.T) {
	ctx, pool, done := lookbackSetup(t)
	defer done()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	execAll(ctx, t, tx, `SET LOCAL search_path TO golden, public`, `
		CREATE TEMP TABLE shift_elig (id_equipment int, ts_value timestamptz, ts_end timestamptz, target_customized boolean);
		INSERT INTO shift_elig SELECT 910, date_trunc('hour', now()) - interval '3 hours', date_trunc('hour', now()) - interval '2 hours', false;
		CREATE TEMP TABLE hour_elig (id_equipment int, ts_value timestamptz, target_customized boolean);
		INSERT INTO hour_elig SELECT 910, date_trunc('hour', now()) - interval '2 hours', false;
		INSERT INTO golden.equipment_oee_shift (id_equipment, ts_value, ts_end, recalc_needed, ideal_speed, gross, net)
		SELECT 910, date_trunc('hour', now()) - interval '3 hours', date_trunc('hour', now()) - interval '2 hours', true, 100, 0, 0;
		INSERT INTO golden.equipment_oee_hourly (id_equipment, ts_value, recalc_needed, ideal_speed, gross, net)
		SELECT 910, date_trunc('hour', now()) - interval '2 hours', true, 100, 0, 0;
		INSERT INTO golden.equipment_events (id_equipment, ts_event, ts_end, status, planned_downtime, change_over)
		VALUES (910, date_trunc('hour', now()) - interval '30 days', NULL, 10, true, false);`,
		fmtRP(hourEventsSQL, "golden", plannedDowntimeExpr(false)),
		fmtRP(shiftEventsSQL, "golden", plannedDowntimeExpr(false)),
		fmtRP(shiftEventsUpdateSQL, "golden"))

	for _, tbl := range []string{"equipment_oee_shift", "equipment_oee_hourly"} {
		var planned, avail float64
		var recalc bool
		if err := tx.QueryRow(ctx, `SELECT COALESCE(planned_downtime,-1), COALESCE(available_time,-1), recalc_needed FROM golden.`+tbl+` WHERE id_equipment = 910`).
			Scan(&planned, &avail, &recalc); err != nil {
			t.Fatal(err)
		}
		if !near(planned, 3600) || !near(avail, 0) || recalc {
			t.Errorf("%s events pass: planned_downtime=%v available_time=%v recalc_needed=%v, want 3600/0/false (old SQL: no event in range → row never updated)", tbl, planned, avail, recalc)
		}
	}
}
