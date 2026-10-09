//go:build golden

// P12 deadlock regression (2026-09-24): the live hour path must NEVER wait on a row
// another transaction holds (the hour backfill), or the two invert lock order across
// equipment_oee_daily / equipment_oee_hourly and deadlock (40P01 ~1–2×/h on staging).
//
// A "backfill" tx holds row locks on one hourly + one daily row; the live reflag and
// live cascade-day then run with lock_timeout=2s and must (1) not wait, (2) skip exactly
// the held rows, (3) flag the free rows. A NEGATIVE CONTROL runs the old blocking
// cascade against the same lock and must time out — proving the test really contends.
// Finally the held row is re-flagged on the next tick once the lock is released.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run Golden
package rollup

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const deadlockGoldenFixture = `
	DROP SCHEMA IF EXISTS gdl CASCADE;
	CREATE SCHEMA gdl;
	CREATE TABLE gdl.equipments (id_equipment int PRIMARY KEY, tp_equipment int);
	CREATE TABLE gdl.equipment_oee_hourly (id_equipment int, ts_value timestamptz, recalc_needed boolean,
	    PRIMARY KEY (id_equipment, ts_value));
	CREATE TABLE gdl.equipment_oee_daily (LIKE gdl.equipment_oee_hourly INCLUDING ALL);
	CREATE FUNCTION gdl.piot_get_day_begin_by_equipment(eq int, t timestamptz)
	  RETURNS TABLE (ts_value_production timestamptz)
	  AS 'SELECT date_trunc(''day'', $2)' LANGUAGE sql;
	INSERT INTO gdl.equipments VALUES (30, 3), (31, 3);
	INSERT INTO gdl.equipment_oee_hourly VALUES
	  (30, date_trunc('hour', now()) - interval '1 hour', false),  -- held by the "backfill"
	  (31, date_trunc('hour', now()) - interval '1 hour', false),  -- free
	  (31, date_trunc('hour', now()), true);                       -- already flagged
	INSERT INTO gdl.equipment_oee_daily VALUES
	  (30, date_trunc('day', now()), false),                       -- held by the "backfill"
	  (31, date_trunc('day', now()), false);                       -- free`

func TestGoldenHourLivePathNeverWaits(t *testing.T) {
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
	if _, err := pool.Exec(ctx, deadlockGoldenFixture); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	// hour_elig (normally built by hourEligibleSQL) for both equipments' current hour.
	const elig = `CREATE TEMP TABLE hour_elig ON COMMIT DROP AS
	  SELECT id_equipment, date_trunc('hour', now()) AS ts_value FROM gdl.equipments`

	// the "backfill": holds one hourly + one daily row (eq 30) for the whole test.
	bf, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer bf.Rollback(ctx)
	if _, err := bf.Exec(ctx, `SELECT 1 FROM gdl.equipment_oee_hourly WHERE id_equipment = 30 FOR UPDATE`); err != nil {
		t.Fatal(err)
	}
	if _, err := bf.Exec(ctx, `SELECT 1 FROM gdl.equipment_oee_daily WHERE id_equipment = 30 FOR UPDATE`); err != nil {
		t.Fatal(err)
	}

	liveTx := func(stmts ...string) error {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		for _, s := range append([]string{`SET LOCAL search_path TO gdl, public`, `SET LOCAL lock_timeout = '2s'`, elig}, stmts...) {
			if _, err := tx.Exec(ctx, s); err != nil {
				return err
			}
		}
		return tx.Commit(ctx)
	}

	// NEGATIVE CONTROL: the old blocking cascade must wait on the held daily row.
	err = liveTx(fmtRP(hourCascadeDaySQL, "gdl"))
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "55P03" {
		t.Fatalf("negative control: blocking cascade should hit lock_timeout (55P03), got %v — the test is not contending", err)
	}

	// THE FIX: live reflag + live cascade complete without waiting.
	if err := liveTx(fmtRP(hourReflagSQL, "gdl"), fmtRP(hourCascadeDayLiveSQL, "gdl")); err != nil {
		t.Fatalf("live path waited on a lock held by another tx (deadlock precondition): %v", err)
	}
	flag := func(table string, eq int, hourOffset string) bool {
		var v bool
		q := `SELECT recalc_needed FROM gdl.` + table + ` WHERE id_equipment = $1 AND ts_value = ` + hourOffset
		if err := pool.QueryRow(ctx, q, eq).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	prevHour := `date_trunc('hour', now()) - interval '1 hour'`
	today := `date_trunc('day', now())`
	if flag("equipment_oee_hourly", 30, prevHour) {
		t.Error("reflag touched the hourly row held by the backfill (must SKIP LOCKED)")
	}
	if !flag("equipment_oee_hourly", 31, prevHour) {
		t.Error("reflag did not flag the free hourly row")
	}
	if flag("equipment_oee_daily", 30, today) {
		t.Error("live cascade touched the daily row held by the backfill (must SKIP LOCKED)")
	}
	if !flag("equipment_oee_daily", 31, today) {
		t.Error("live cascade did not flag the free daily row")
	}

	// next tick after the backfill commits: the skipped hourly row is re-flagged.
	if err := bf.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := liveTx(fmtRP(hourReflagSQL, "gdl")); err != nil {
		t.Fatal(err)
	}
	if !flag("equipment_oee_hourly", 30, prevHour) {
		t.Error("skipped hourly row was not re-flagged on the next tick")
	}
}
