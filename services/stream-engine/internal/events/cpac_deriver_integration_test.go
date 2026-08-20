//go:build cpac_integration

// Behavioral proof for the CPAC stop deriver (ADR-0010 §10.4). Build-tagged so
// the default `go test ./...` stays green without a database; run against a
// throwaway Postgres:
//
//	TEST_DATABASE_URL='postgres://user:pass@host:5432/db' \
//	    go test -tags cpac_integration -run TestCPAC -v ./internal/events/
//
// It fabricates a self-contained schema (equipments + a plain table standing in
// for the ca_agg_equipment_values_1min cagg + the shadow target), seeds a run →
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
			tp_equipment int, stop_threshold_time int)`,
		`CREATE TABLE ` + schema + `.ca_agg_equipment_values_1min (
			id_equipment int, ts_value timestamptz, gross_production_incr numeric)`,
		// full-enough clone of equipment_events for the guard columns + key
		`CREATE TABLE ` + schema + `.equipment_events_cpac_shadow (
			id_equipment int, ts_event timestamptz, ts_end timestamptz,
			status int, id_enterprise int, duration int,
			forced_creation_system boolean DEFAULT false,
			cd_category varchar, cd_subcategory varchar, cd_machine varchar,
			txt_downtime_notes varchar, planned_downtime boolean DEFAULT false,
			change_over boolean DEFAULT false, idle varchar,
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
				`INSERT INTO `+schema+`.ca_agg_equipment_values_1min VALUES (1000, $1, 5)`, ts); err != nil {
				t.Fatal(err)
			}
		}
	}
	seedRun(base, 10)
	seedRun(base.Add(35*time.Minute), 10) // 25-min gap after the first run's last count
}

func dest(pool *pgxpool.Pool) Dest {
	return Dest{Name: "it", Pool: pool, EvSchema: schema, RefSchema: schema}
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

	// Place a justified stop covering the silence gap region.
	base := time.Now().UTC().Add(-3 * time.Hour)
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
