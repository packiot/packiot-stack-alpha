//go:build golden

package rollup

import (
	"context"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// TestGoldenStrandedSweep — only flags no consumer can ever drain are cleared;
// every row a live pass can still reach keeps its flag.
func TestGoldenStrandedSweep(t *testing.T) {
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
		`CREATE TABLE golden.equipments (id_equipment int PRIMARY KEY, tp_equipment int, id_enterprise int)`,
		`CREATE TABLE golden.production_orders_runtime (id_production_order_runtime int, runtime_timerange tstzrange, recalc_needed boolean)`,
		`CREATE TABLE golden.production_orders (id_production_order int, status int, ts_start timestamptz, ts_end timestamptz, recalc_needed boolean)`,
		`CREATE TABLE golden.equipment_oee_shift (id_equipment int, ts_value timestamptz, recalc_needed boolean)`,
		`CREATE TABLE golden.equipment_oee_hourly (id_equipment int, ts_value timestamptz, recalc_needed boolean)`,
		`CREATE TABLE golden.equipment_oee_daily (id_equipment int, ts_value date, recalc_needed boolean)`,
		`CREATE TABLE golden.equipment_oee_weekly (id_equipment int, ts_value date, recalc_needed boolean)`,
		`CREATE TABLE golden.equipment_oee_monthly (id_equipment int, ts_value date, recalc_needed boolean)`,
		`INSERT INTO golden.equipments VALUES (1, 3, 5), (2, 1, 5), (3, 1, 6)`,
		// runtime: 1 closed 2 months ago (stranded) · 2 closed 1 day ago (48 h re-flag band) · 3 open since 2 months (re-flagged every pass)
		`INSERT INTO golden.production_orders_runtime VALUES
		   (1, tstzrange(now() - interval '62 days', now() - interval '61 days'), true),
		   (2, tstzrange(now() - interval '2 days', now() - interval '1 day'), true),
		   (3, tstzrange(now() - interval '60 days', NULL), true)`,
		// headers: 10 finished 2 months ago (stranded) · 11 RUNNING since 2 months (kept) · 12 finished yesterday (kept)
		`INSERT INTO golden.production_orders VALUES
		   (10, 3, now() - interval '62 days', now() - interval '61 days', true),
		   (11, 2, now() - interval '62 days', NULL, true),
		   (12, 3, now() - interval '2 days', now() - interval '1 day', true)`,
		// shift: line 40 d (stranded) · line 1 d (kept) · tp=1 ent 5 non-machine-level (stranded) · tp=1 ent 6 machine-level (kept)
		`INSERT INTO golden.equipment_oee_shift VALUES
		   (1, now() - interval '40 days', true), (1, now() - interval '1 day', true),
		   (2, now() - interval '1 day', true), (3, now() - interval '1 day', true)`,
		// hour: line 12 d (stranded) · line 2 d (kept, backfill reach) · tp=1 (stranded)
		`INSERT INTO golden.equipment_oee_hourly VALUES
		   (1, now() - interval '12 days', true), (1, now() - interval '2 days', true), (2, now() - interval '2 days', true)`,
		// day: line 40 d (stranded, past the 1-month day window) · line 2 d (kept) · line tomorrow (kept, future)
		//      · tp=1 2 d (stranded — the 2026-10-14 class) · tp=1 of machine-level ent 6 (stranded too: no day pass computes tp=1)
		`INSERT INTO golden.equipment_oee_daily VALUES
		   (1, (now() - interval '40 days')::date, true), (1, (now() - interval '2 days')::date, true),
		   (1, (now() + interval '1 day')::date, true), (2, (now() - interval '2 days')::date, true),
		   (3, (now() - interval '2 days')::date, true)`,
		// week/month: line 400 d (stranded, past the 1-year window) · line this bucket (kept) · tp=1 this bucket (stranded)
		`INSERT INTO golden.equipment_oee_weekly VALUES
		   (1, date_trunc('week', now() - interval '400 days')::date, true), (1, date_trunc('week', now())::date, true),
		   (2, date_trunc('week', now())::date, true)`,
		`INSERT INTO golden.equipment_oee_monthly VALUES
		   (1, date_trunc('month', now() - interval '400 days')::date, true), (1, date_trunc('month', now())::date, true),
		   (2, date_trunc('month', now())::date, true)`,
	} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden", SilverSchema: "golden", GoldSchema: "golden", GrainSchema: "golden", ConfigSchema: "golden"}
	scope := StrandedScope{POWindow: "1 month", MachineLevelEnterprises: []int{6}, HourHorizon: "10 days"}
	got, err := RunStrandedSweep(ctx, d, scope, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int64{"production_orders_runtime": 1, "production_orders": 1, "equipment_oee_shift": 2, "equipment_oee_hourly": 2,
		"equipment_oee_daily": 3, "equipment_oee_weekly": 2, "equipment_oee_monthly": 2}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s cleared %d, want %d", k, got[k], v)
		}
	}
	var kept int
	if err := pool.QueryRow(ctx, `SELECT
	    (SELECT count(*) FROM golden.production_orders_runtime WHERE recalc_needed AND id_production_order_runtime IN (2, 3)) +
	    (SELECT count(*) FROM golden.production_orders WHERE recalc_needed AND id_production_order IN (11, 12)) +
	    (SELECT count(*) FROM golden.equipment_oee_shift WHERE recalc_needed) +
	    (SELECT count(*) FROM golden.equipment_oee_hourly WHERE recalc_needed) +
	    (SELECT count(*) FROM golden.equipment_oee_daily WHERE recalc_needed AND id_equipment = 1) +
	    (SELECT count(*) FROM golden.equipment_oee_daily WHERE recalc_needed AND id_equipment <> 1) +
	    (SELECT count(*) FROM golden.equipment_oee_weekly WHERE recalc_needed AND id_equipment = 1) +
	    (SELECT count(*) FROM golden.equipment_oee_monthly WHERE recalc_needed AND id_equipment = 1)`).Scan(&kept); err != nil {
		t.Fatal(err)
	}
	// day: line 2 d + tomorrow kept, no tp=1 left; week/month: the current line bucket kept
	if kept != 2+2+2+1+2+0+1+1 {
		t.Fatalf("live flags kept = %d, want 11", kept)
	}
	// idempotent: nothing left to clear
	got, err = RunStrandedSweep(ctx, d, scope, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range got {
		if v != 0 {
			t.Errorf("second sweep cleared %d from %s", v, k)
		}
	}
}
