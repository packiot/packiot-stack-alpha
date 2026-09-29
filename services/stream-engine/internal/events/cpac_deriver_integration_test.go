//go:build cpac_integration

// Behavioral proof for the CPAC stop deriver (ADR-0010 §10.4). Build-tagged so
// the default `go test ./...` stays green without a database; run against a
// throwaway Postgres:
//
//	TEST_DATABASE_URL='postgres://user:pass@host:5432/db' \
//	    go test -tags cpac_integration -run TestCPAC -v ./internal/events/
//
// It fabricates a self-contained schema (equipments + a plain table standing in
// for the equipment_categorical_1min cagg + the shadow target), seeds a run →
// stop → run count pattern plus an operator-justified event, and proves the two
// invariants that gate enablement: IDEMPOTENCY and NEVER-CLOBBER-A-HUMAN-EDIT.
package events

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func mustPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	return pool
}

const schema = "cpac_it"

func setupSchema(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	ddl := []string{
		`DROP SCHEMA IF EXISTS ` + schema + ` CASCADE`,
		`CREATE SCHEMA ` + schema,
		`CREATE TABLE ` + schema + `.equipments (
			id_equipment int PRIMARY KEY, id_enterprise int, status_type int,
			tp_equipment int, stop_threshold_time int,
			lead_machine int, downtime_from_lead_machine boolean)`,
		`CREATE TABLE ` + schema + `.equipment_categorical_1min (
			id_equipment int, ts_value timestamptz, gross_production_incr numeric,
			net_production_incr numeric, scrap_incr numeric)`,
		// full-enough clone of equipment_events for the guard columns + key
		`CREATE TABLE ` + schema + `.equipment_events_cpac_shadow (
			id_equipment int, ts_event timestamptz, ts_end timestamptz,
			status int, id_enterprise int, duration int,
			-- NO defaults: matches silver.equipment_events on staging, where these
			-- booleans are nullable without defaults and the deriver's INSERT leaves
			-- planned_downtime/change_over NULL (a DEFAULT false here once masked the
			-- NULL-unsafe guard that made the correct pass + DO UPDATE dead).
			forced_creation_system boolean,
			cd_category varchar, cd_subcategory varchar, cd_machine varchar,
			txt_downtime_notes varchar, planned_downtime boolean,
			change_over boolean, idle varchar,
			UNIQUE (id_equipment, ts_event))`,
	}
	for _, s := range ddl {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("ddl %q: %v", s, err)
		}
	}
	// one status_type=0 machine, threshold NULL → falls back to the 300s default.
	if _, err := pool.Exec(ctx, `INSERT INTO `+schema+`.equipments VALUES (1000, 999, 0, 1, NULL)`); err != nil {
		t.Fatal(err)
	}
	// Count pattern: 10 productive minutes, a 25-min silence (a stop, > 300s),
	// then 10 more productive minutes — anchored so the whole thing sits inside
	// the deriver's 25h window and clear of the 10s warmup.
	base := time.Now().UTC().Add(-3 * time.Hour)
	seedRun := func(start time.Time, n int) {
		for i := 0; i < n; i++ {
			ts := start.Add(time.Duration(i) * time.Minute)
			if _, err := pool.Exec(ctx,
				`INSERT INTO `+schema+`.equipment_categorical_1min VALUES (1000, $1, 5)`, ts); err != nil {
				t.Fatal(err)
			}
		}
	}
	seedRun(base, 10)
	seedRun(base.Add(35*time.Minute), 10) // 25-min gap after the first run's last count
}

func dest(pool *pgxpool.Pool) Dest {
	return Dest{Name: "it", Pool: pool, EvSchema: schema, RefSchema: schema, SilverSchema: schema}
}

var itCfg = CPACConfig{Enterprises: []int{999}, ThresholdDefSec: 300, TargetTable: "equipment_events_cpac_shadow"}

type evRow struct {
	Eq       int
	TsEvent  time.Time
	TsEnd    *time.Time
	Status   int
	Duration *int
	Forced   bool
	Category *string
}

func dump(t *testing.T, pool *pgxpool.Pool) []evRow {
	t.Helper()
	rows, err := pool.Query(context.Background(),
		`SELECT id_equipment, ts_event, ts_end, status, duration, forced_creation_system, cd_category
		   FROM `+schema+`.equipment_events_cpac_shadow ORDER BY id_equipment, ts_event`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []evRow
	for rows.Next() {
		var r evRow
		if err := rows.Scan(&r.Eq, &r.TsEvent, &r.TsEnd, &r.Status, &r.Duration, &r.Forced, &r.Category); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

// TestCPACDetectsStopAndIsIdempotent: the run→silence→run pattern yields an
// alternating 6/10 stream with exactly one detected stop, and a second identical
// pass changes nothing (no duplicate rows, identical values).
func TestCPACDetectsStopAndIsIdempotent(t *testing.T) {
	pool := mustPool(t)
	defer pool.Close()
	setupSchema(t, pool)
	ctx := context.Background()

	if _, _, err := RunOnceCPAC(ctx, dest(pool), itCfg); err != nil {
		t.Fatalf("run 1: %v", err)
	}
	after1 := dump(t, pool)

	var closedStops, runs int
	for _, r := range after1 {
		switch r.Status {
		case 10:
			if r.TsEnd != nil { // interior gap stop (a later run transition closed it)
				closedStops++
			}
			// a trailing OPEN stop (ts_end NULL) is legitimate — the machine has
			// produced nothing since the last seeded count — so it is not asserted.
		case 6:
			runs++
		}
	}
	if closedStops != 1 {
		t.Errorf("expected exactly 1 closed interior stop (status=10, ts_end set), got %d (rows=%d)", closedStops, len(after1))
	}
	if runs != 2 {
		t.Errorf("expected exactly 2 running intervals (status=6), got %d", runs)
	}

	// Idempotency: re-run on the SAME data must produce an identical row set.
	if _, _, err := RunOnceCPAC(ctx, dest(pool), itCfg); err != nil {
		t.Fatalf("run 2: %v", err)
	}
	after2 := dump(t, pool)
	if len(after1) != len(after2) {
		t.Fatalf("idempotency broken: run1 %d rows, run2 %d rows", len(after1), len(after2))
	}
	for i := range after1 {
		a, b := after1[i], after2[i]
		if a.Eq != b.Eq || !a.TsEvent.Equal(b.TsEvent) || a.Status != b.Status {
			t.Errorf("idempotency broken at row %d: %+v vs %+v", i, a, b)
		}
	}
}

// TestCPACNeverClobbersJustifiedEvent: an operator justifies a stop (sets
// cd_category, forced_creation_system stays false — a plain 30810 justify). A
// re-derivation must leave that row byte-unchanged and must NOT mint a derived
// row inside its covered span.
func TestCPACNeverClobbersJustifiedEvent(t *testing.T) {
	pool := mustPool(t)
	defer pool.Close()
	setupSchema(t, pool)
	ctx := context.Background()

	// Place a justified stop covering the silence gap region. Truncated to µs
	// (timestamptz precision) so the round-tripped ts_end compares equal.
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Microsecond)
	jStart := base.Add(9 * time.Minute) // inside/around the derived stop region
	jEnd := base.Add(34 * time.Minute)
	if _, err := pool.Exec(ctx,
		`INSERT INTO `+schema+`.equipment_events_cpac_shadow
		   (id_equipment, ts_event, ts_end, status, id_enterprise, duration,
		    forced_creation_system, cd_category, txt_downtime_notes)
		 VALUES (1000, $1, $2, 10, 999, $3, false, 'MECH', 'operator note')`,
		jStart, jEnd, int(jEnd.Sub(jStart).Seconds())); err != nil {
		t.Fatal(err)
	}

	if _, _, err := RunOnceCPAC(ctx, dest(pool), itCfg); err != nil {
		t.Fatalf("run: %v", err)
	}

	// The justified row must survive intact.
	var cat, note *string
	var tsEnd time.Time
	if err := pool.QueryRow(ctx,
		`SELECT cd_category, txt_downtime_notes, ts_end FROM `+schema+`.equipment_events_cpac_shadow
		  WHERE id_equipment=1000 AND ts_event=$1`, jStart).Scan(&cat, &note, &tsEnd); err != nil {
		t.Fatalf("justified row vanished: %v", err)
	}
	if cat == nil || *cat != "MECH" || note == nil || *note != "operator note" {
		t.Errorf("justification clobbered: cat=%v note=%v", cat, note)
	}
	if !tsEnd.Equal(jEnd) {
		t.Errorf("justified ts_end moved: got %s want %s", tsEnd, jEnd)
	}
	// No derived row may fall inside the human-protected span (append-only).
	var covering int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.equipment_events_cpac_shadow
		  WHERE id_equipment=1000 AND NOT (cd_category IS NOT NULL OR forced_creation_system)
		    AND ts_event > $1 AND ts_event < $2`, jStart, jEnd).Scan(&covering); err != nil {
		t.Fatal(err)
	}
	if covering != 0 {
		t.Errorf("append-only violated: %d derived rows minted inside the justified span", covering)
	}
	fmt.Fprintln(os.Stderr, "no-clobber + append-only: OK")
}

// seedNetOnlyLines adds the Bispharma net-only-lead shape next to the gross
// machine 1000 from setupSchema:
//   - line 2000 (downtime_from_lead_machine) whose lead 2001 reports ONLY net
//     (L18 TAMPADEIRA / BISNAGO M67x), plus a non-lead net-only member 2002 (an
//     intermediate station like S3/S4/S5 — must stay event-free);
//   - line 3000 with downtime_from_lead_machine=false whose net-only lead 3001
//     must stay event-free (the per-line gate).
//
// Each net-only member gets the same run -> 25-min silence -> run pattern.
func seedNetOnlyLines(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	for _, q := range []string{
		`INSERT INTO ` + schema + `.equipments VALUES (2000, 999, 0, 3, NULL, 2001, true)`,
		`INSERT INTO ` + schema + `.equipments VALUES (2001, 999, 0, 1, NULL, NULL, NULL)`,
		`INSERT INTO ` + schema + `.equipments VALUES (2002, 999, 0, 1, NULL, NULL, NULL)`,
		`INSERT INTO ` + schema + `.equipments VALUES (3000, 999, 0, 3, NULL, 3001, false)`,
		`INSERT INTO ` + schema + `.equipments VALUES (3001, 999, 0, 1, NULL, NULL, NULL)`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	base := time.Now().UTC().Add(-3 * time.Hour)
	for _, eq := range []int{2001, 2002, 3001} {
		for _, start := range []time.Time{base, base.Add(35 * time.Minute)} {
			for i := 0; i < 10; i++ {
				if _, err := pool.Exec(ctx,
					`INSERT INTO `+schema+`.equipment_categorical_1min
					   (id_equipment, ts_value, gross_production_incr, net_production_incr)
					 VALUES ($1, $2, 0, 5)`, eq, start.Add(time.Duration(i)*time.Minute)); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
}

func byEq(rows []evRow) map[int][]evRow {
	out := map[int][]evRow{}
	for _, r := range rows {
		out[r.Eq] = append(out[r.Eq], r)
	}
	return out
}

// TestCPACLeadActivityNetOnlyLead: a line whose lead reports only NET got zero
// events under the gross-only rule (the Bispharma 8-line gap). With LeadActivity
// the lead gets the run/stop/run stream; a non-lead net-only member and a lead of
// a downtime_from_lead_machine=false line stay event-free; the gross machine's
// stream is identical in both modes.
func TestCPACLeadActivityNetOnlyLead(t *testing.T) {
	pool := mustPool(t)
	defer pool.Close()
	setupSchema(t, pool)
	seedNetOnlyLines(t, pool)
	ctx := context.Background()

	// Gross-only (the CPACK shadow / pre-fix behaviour): reproduces the bug.
	if _, _, err := RunOnceCPAC(ctx, dest(pool), itCfg); err != nil {
		t.Fatalf("gross-only run: %v", err)
	}
	off := byEq(dump(t, pool))
	for _, eq := range []int{2001, 2002, 3001} {
		if len(off[eq]) != 0 {
			t.Errorf("gross-only mode must mint nothing for net-only member %d, got %d rows", eq, len(off[eq]))
		}
	}
	if len(off[1000]) == 0 {
		t.Fatal("gross machine 1000 must have events in gross-only mode")
	}

	// Lead-activity mode (the live counters-only instance).
	cfg := itCfg
	cfg.LeadActivity = true
	if _, _, err := RunOnceCPAC(ctx, dest(pool), cfg); err != nil {
		t.Fatalf("lead-activity run: %v", err)
	}
	onRows := dump(t, pool)
	on := byEq(onRows)
	var stops, runs int
	for _, r := range on[2001] {
		switch r.Status {
		case 10:
			if r.TsEnd != nil {
				stops++
			}
		case 6:
			runs++
		}
	}
	if stops != 1 || runs != 2 {
		t.Errorf("net-only lead 2001: want 1 closed stop + 2 runs, got stops=%d runs=%d (%d rows)", stops, runs, len(on[2001]))
	}
	if len(on[2002]) != 0 {
		t.Errorf("non-lead net-only member 2002 must stay event-free, got %d rows", len(on[2002]))
	}
	if len(on[3001]) != 0 {
		t.Errorf("lead of a downtime_from_lead_machine=false line must stay event-free, got %d rows", len(on[3001]))
	}
	if len(on[2000]) != 0 || len(on[3000]) != 0 {
		t.Errorf("lines themselves must not get events (no own counters)")
	}
	if len(on[1000]) != len(off[1000]) {
		t.Fatalf("gross machine stream changed: %d vs %d rows", len(off[1000]), len(on[1000]))
	}
	for i := range off[1000] {
		a, b := off[1000][i], on[1000][i]
		if !a.TsEvent.Equal(b.TsEvent) || a.Status != b.Status {
			t.Errorf("gross machine row %d changed: %+v vs %+v", i, a, b)
		}
	}

	// Idempotent in lead mode too.
	if _, _, err := RunOnceCPAC(ctx, dest(pool), cfg); err != nil {
		t.Fatalf("lead-activity run 2: %v", err)
	}
	again := dump(t, pool)
	if len(again) != len(onRows) {
		t.Fatalf("lead-activity pass not idempotent: %d rows then %d", len(onRows), len(again))
	}
	for i := range again {
		if again[i].Eq != onRows[i].Eq || !again[i].TsEvent.Equal(onRows[i].TsEvent) || again[i].Status != onRows[i].Status {
			t.Errorf("lead-activity idempotency broken at row %d: %+v vs %+v", i, onRows[i], again[i])
		}
	}
}

func countStatus(t *testing.T, pool *pgxpool.Pool, eq, status int) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM `+schema+`.equipment_events_cpac_shadow WHERE id_equipment=$1 AND status=$2`,
		eq, status).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// TestCPACWindowEdgeNoPhantomRunning: a CONTINUOUS run that crosses the 25h
// window's trailing edge must not mint a RUNNING row at the first in-window
// minute. Time passing is simulated by shifting the seeded minutes 3 min into
// the past between ticks. Pre-fix (verified by running this test against the
// old deriver): a phantom status-6 row at the first in-window minute (in
// production a NEW one every tick, since the edge moves with now(); here the
// seeded minutes move instead, so it re-lands on the same key) plus 3 stops,
// because the NULL-unsafe guard kept every superseded stop.
func TestCPACWindowEdgeNoPhantomRunning(t *testing.T) {
	pool := mustPool(t)
	defer pool.Close()
	setupSchema(t, pool)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `INSERT INTO `+schema+`.equipments VALUES (4000, 999, 0, 1, NULL)`); err != nil {
		t.Fatal(err)
	}
	// one productive minute every minute from now-27h to now-23h
	start := time.Now().UTC().Add(-27 * time.Hour).Truncate(time.Minute)
	if _, err := pool.Exec(ctx,
		`INSERT INTO `+schema+`.equipment_categorical_1min (id_equipment, ts_value, gross_production_incr)
		 SELECT 4000, g, 5 FROM generate_series($1::timestamptz, $1::timestamptz + interval '4 hours', interval '1 minute') g`,
		start); err != nil {
		t.Fatal(err)
	}
	for tick := 0; tick < 3; tick++ {
		if _, _, err := RunOnceCPAC(ctx, dest(pool), itCfg); err != nil {
			t.Fatalf("tick %d: %v", tick, err)
		}
		if _, err := pool.Exec(ctx,
			`UPDATE `+schema+`.equipment_categorical_1min SET ts_value = ts_value - interval '3 minutes' WHERE id_equipment = 4000`); err != nil {
			t.Fatal(err)
		}
	}
	if n := countStatus(t, pool, 4000, 6); n != 0 {
		t.Errorf("window-edge phantom RUNNING rows: got %d status-6 rows, want 0 (the run started before the window)", n)
	}
	if n := countStatus(t, pool, 4000, 10); n != 1 {
		t.Errorf("want exactly 1 stop (the run's end; superseded stops removed by the correct pass), got %d", n)
	}
}

// TestCPACCorrectPassRemovesSupersededStop: late counts fill a silence the
// deriver already booked as a stop. With planned_downtime/change_over NULL (as
// the deriver inserts them) the next tick must DELETE the stale stop and
// re-chain the running row (DO UPDATE). Pre-fix the NULL guard kept both stale.
func TestCPACCorrectPassRemovesSupersededStop(t *testing.T) {
	pool := mustPool(t)
	defer pool.Close()
	setupSchema(t, pool)
	ctx := context.Background()
	if _, _, err := RunOnceCPAC(ctx, dest(pool), itCfg); err != nil {
		t.Fatal(err)
	}
	if n := countStatus(t, pool, 1000, 10); n < 1 {
		t.Fatalf("setup: expected the silence to be booked as a stop, got %d", n)
	}
	// late data: the 25-min silence was actually productive
	base := time.Now().UTC().Add(-3 * time.Hour)
	for i := 10; i < 35; i++ {
		if _, err := pool.Exec(ctx,
			`INSERT INTO `+schema+`.equipment_categorical_1min (id_equipment, ts_value, gross_production_incr) VALUES (1000, $1, 5)`,
			base.Add(time.Duration(i)*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := RunOnceCPAC(ctx, dest(pool), itCfg); err != nil {
		t.Fatal(err)
	}
	var closedStops, runs int
	var runEnd *time.Time
	var tailStop time.Time
	for _, r := range dump(t, pool) {
		if r.Eq != 1000 {
			continue
		}
		switch r.Status {
		case 10:
			if r.TsEnd != nil {
				closedStops++
			} else {
				tailStop = r.TsEvent
			}
		case 6:
			runs++
			runEnd = r.TsEnd
		}
	}
	if closedStops != 0 || runs != 1 {
		t.Errorf("superseded stop not corrected: closed stops=%d runs=%d (want 0 and 1)", closedStops, runs)
	}
	if runEnd == nil || !runEnd.Equal(tailStop) {
		t.Errorf("the surviving run must be re-chained to the trailing stop %s (DO UPDATE), got ts_end %v", tailStop, runEnd)
	}
}
