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

// TestGoldenCloserLongOpenStops pins the long-open pass (2026-09-24). The main pass only
// sees ts_event >= now()-horizon, so a stop that OUTLIVED the horizon was never bounded
// when its successor arrived — CPACK orphans of 4–52 days (oldest 2024-06-03) rendered
// as open-ended stops in every Events-tab window. Drives the real RunOnceClose.
func TestGoldenCloserLongOpenStops(t *testing.T) {
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
	if _, err := pool.Exec(ctx, closerFixture+`
		INSERT INTO gcl.equipments VALUES (4,7,1,0,300),(5,7,1,0,300),(6,7,1,0,300);
		-- (4) stop 5 days ago (outside the 72 h horizon), successor run 1 day ago → bounded at the run
		INSERT INTO gcl.equipment_events (id_equipment_event,id_equipment,ts_event,status) VALUES
		  (401,4, now()-interval '5 days', 10), (402,4, now()-interval '1 day', 6);
		-- (5) stop 5 days ago, NO successor → genuinely ongoing, stays open
		INSERT INTO gcl.equipment_events (id_equipment_event,id_equipment,ts_event,status) VALUES (501,5, now()-interval '5 days', 10);
		-- (6) stop 100 days ago, successor 90 days ago → beyond the 60-day long horizon, untouched
		INSERT INTO gcl.equipment_events (id_equipment_event,id_equipment,ts_event,status) VALUES
		  (601,6, now()-interval '100 days', 10), (602,6, now()-interval '90 days', 6);`); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if _, err := RunOnceClose(ctx, Dest{Pool: pool, SilverSchema: "gcl", RefSchema: "gcl"},
		CloserConfig{Enterprises: []int{7}, ThresholdDefSec: 300, HorizonHours: 72, LongHorizonDays: 60}); err != nil {
		t.Fatalf("RunOnceClose: %v", err)
	}
	end := func(id int) (*time.Time, *int) {
		var e *time.Time
		var d *int
		if err := pool.QueryRow(ctx, `SELECT ts_end, duration FROM gcl.equipment_events WHERE id_equipment_event=$1`, id).Scan(&e, &d); err != nil {
			t.Fatal(err)
		}
		return e, d
	}
	if e, d := end(401); e == nil || d == nil || *d != 4*86400 {
		t.Errorf("stop that outlived the horizon: ts_end=%v duration=%v, want closed at its successor (4 days)", e, d)
	}
	if e, _ := end(501); e != nil {
		t.Errorf("long stop without a successor was closed at %v — it must stay open", e)
	}
	if e, _ := end(601); e != nil {
		t.Errorf("stop beyond the long horizon was touched (closed at %v) — the pass must stay bounded", e)
	}
	// the original cases still hold
	if e, _ := end(101); e != nil {
		t.Errorf("trailing open STOP was closed at %v", e)
	}
}

// TestGoldenCloserRebindsClosedRows pins the 2026-09-28 rebind. The count-silence
// close runs before late or out-of-order events arrive, so a row could be closed at
// its own start (zero-length) or past its successor (overlap); the old IS NULL guard
// made that permanent (~350 h of CPACK downtime lost in 14 days). Once a successor
// exists the row must end at the successor's start. Also pins the true-PK match: a
// row on another tenant that shares a (non-unique) id_equipment_event is untouched.
func TestGoldenCloserRebindsClosedRows(t *testing.T) {
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
	const fixture = `
	DROP SCHEMA IF EXISTS gcl CASCADE; CREATE SCHEMA gcl;
	CREATE TABLE gcl.equipments (id_equipment int PRIMARY KEY, id_enterprise int, tp_equipment int,
	    status_type int, stop_threshold_time int);
	CREATE TABLE gcl.equipment_categorical_1min (id_equipment int, ts_value timestamptz, gross_production_incr double precision);
	CREATE TABLE gcl.equipment_events (id_equipment_event bigint, id_equipment int, ts_event timestamptz,
	    ts_end timestamptz, duration int, status int, last_update timestamptz,
	    cd_category text, cd_subcategory text, cd_machine text, txt_downtime_notes text,
	    planned_downtime boolean, change_over boolean, idle boolean,
	    PRIMARY KEY (id_equipment, ts_event));
	INSERT INTO gcl.equipments VALUES (4,7,1,0,300),(5,7,1,0,300),(6,8,1,0,300);
	INSERT INTO gcl.equipment_events (id_equipment_event,id_equipment,ts_event,ts_end,status,cd_category) VALUES
	  -- RUN closed zero-length at its own start (arrived late); successor at -40m
	  (401,4, now()-interval '55 minutes', now()-interval '55 minutes', 6, NULL),
	  (403,4, now()-interval '40 minutes', NULL, 10, NULL),
	  -- operator-justified STOP closed PAST its successor (overlap): ended -5m, successor -15m
	  (404,5, now()-interval '30 minutes', now()-interval '5 minutes', 10, 'PRG-01'),
	  (405,5, now()-interval '15 minutes', NULL, 6, NULL),
	  -- another tenant's row sharing id 401 (ent 8, out of scope): must stay untouched
	  (401,6, now()-interval '55 minutes', now()-interval '54 minutes', 6, NULL);`
	if _, err := pool.Exec(ctx, fixture); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	sql := fmt.Sprintf(closeStaleOpensSQL, "gcl", "gcl", "", "ev")
	if _, err := pool.Exec(ctx, sql, []int{7}, 300, 72); err != nil {
		t.Fatalf("closer: %v", err)
	}
	endAgo := func(eq, ev int) float64 {
		var end time.Time
		if err := pool.QueryRow(ctx, `SELECT ts_end FROM gcl.equipment_events WHERE id_equipment=$1 AND id_equipment_event=$2`, eq, ev).Scan(&end); err != nil {
			t.Fatal(err)
		}
		return time.Since(end).Minutes()
	}
	if m := endAgo(4, 401); m < 39.5 || m > 40.5 {
		t.Errorf("zero-length RUN with a later successor ended %.1f min ago, want the successor's start (~40)", m)
	}
	if m := endAgo(5, 404); m < 14.5 || m > 15.5 {
		t.Errorf("STOP closed past its successor ended %.1f min ago, want the successor's start (~15)", m)
	}
	var cat string
	if err := pool.QueryRow(ctx, `SELECT cd_category FROM gcl.equipment_events WHERE id_equipment=5 AND id_equipment_event=404`).Scan(&cat); err != nil || cat != "PRG-01" {
		t.Errorf("rebind must keep the operator's category, got %q (%v)", cat, err)
	}
	if m := endAgo(6, 401); m < 53.5 || m > 54.5 {
		t.Errorf("out-of-scope row sharing a non-unique id changed: ended %.1f min ago, want untouched (~54)", m)
	}
}
