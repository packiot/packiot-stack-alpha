//go:build golden

// Golden: the real closeStaleOpensSQL on ephemeral Postgres. Pins the 2026-09-24 fix —
// the trailing count-silence close is RUNNING-only; an open STOP stays open until the next
// transition bounds it (before the fix: ended at its own start, permanently).
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/events -run Golden
package events

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const closerFixture = `
	DROP SCHEMA IF EXISTS gcl CASCADE; CREATE SCHEMA gcl;
	CREATE TABLE gcl.equipments (id_equipment int PRIMARY KEY, id_enterprise int, tp_equipment int,
	    status_type int, stop_threshold_time int);
	CREATE TABLE gcl.equipment_categorical_1min (id_equipment int, ts_value timestamptz, gross_production_incr double precision);
	CREATE TABLE gcl.equipment_events (id_equipment_event bigint PRIMARY KEY, id_equipment int, ts_event timestamptz,
	    ts_end timestamptz, duration int, status int, last_update timestamptz,
	    cd_category text, cd_subcategory text, cd_machine text, txt_downtime_notes text,
	    planned_downtime boolean, change_over boolean, idle boolean);
	-- 3 machines, ent 7, 300 s threshold; last productive minute 30 min ago on each
	INSERT INTO gcl.equipments VALUES (1,7,1,0,300),(2,7,1,0,300),(3,7,1,0,300);
	INSERT INTO gcl.equipment_categorical_1min
	  SELECT id, now() - interval '30 minutes', 10 FROM generate_series(1,3) id;
	-- (1) trailing OPEN STOP that began after the last count → must stay OPEN
	INSERT INTO gcl.equipment_events (id_equipment_event,id_equipment,ts_event,status) VALUES (101,1, now()-interval '28 minutes', 10);
	-- (2) trailing OPEN RUN, counts silent since 30 min → closed at last+thr (25 min ago)
	INSERT INTO gcl.equipment_events (id_equipment_event,id_equipment,ts_event,status) VALUES (201,2, now()-interval '60 minutes', 6);
	-- (3) STOP followed by a RUN → stop bounded exactly at the run's start
	INSERT INTO gcl.equipment_events (id_equipment_event,id_equipment,ts_event,status) VALUES
	  (301,3, now()-interval '50 minutes', 10), (302,3, now()-interval '20 minutes', 6);`

func TestGoldenCloserNeverTruncatesOpenStops(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, closerFixture); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	sql := fmt.Sprintf(closeStaleOpensSQL, "gcl", "gcl", "", "ev")
	if _, err := pool.Exec(ctx, sql, []int{7}, 300, 72); err != nil {
		t.Fatalf("closer: %v", err)
	}
	type row struct {
		open bool
		ageEndMin float64
	}
	get := func(id int) row {
		var r row
		var end *time.Time
		if err := pool.QueryRow(ctx, `SELECT ts_end FROM gcl.equipment_events WHERE id_equipment_event=$1`, id).Scan(&end); err != nil {
			t.Fatal(err)
		}
		r.open = end == nil
		if end != nil {
			r.ageEndMin = time.Since(*end).Minutes()
		}
		return r
	}
	if r := get(101); !r.open {
		t.Errorf("trailing open STOP was closed (ended %.1f min ago) — an ongoing stop must stay open", r.ageEndMin)
	}
	if r := get(201); r.open || r.ageEndMin < 24 || r.ageEndMin > 26 {
		t.Errorf("trailing silent RUN: open=%v ended %.1f min ago, want closed at last-count+thr (~25 min ago)", r.open, r.ageEndMin)
	}
	if r := get(301); r.open || r.ageEndMin < 19.5 || r.ageEndMin > 20.5 {
		t.Errorf("stop followed by a run: open=%v ended %.1f min ago, want the run's start (~20 min ago)", r.open, r.ageEndMin)
	}
}
