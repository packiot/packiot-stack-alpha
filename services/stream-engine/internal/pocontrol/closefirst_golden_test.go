//go:build golden

// Close-first recurrence guard (task #34) — behavior proof against a
// REAL Postgres carrying the exact EXCLUDE constraint dba adds next:
//
//	EXCLUDE USING gist (id_equipment WITH =, runtime_timerange WITH &&)
//
// The point of this test is the constraint: if execStart did not close
// the prior open ("zombie") segment BEFORE inserting the new one, the
// INSERT of [ts,∞) would overlap the still-open [t0,∞) and Postgres
// would raise 23P01 — the exclusion-constraint poison the guard exists
// to prevent. A green run proves the close-first ordering is correct and
// that a normal start never trips the EXCLUDE.
//
//	Run: DATABASE_URL=postgres://user:pass@host/db go test -tags golden \
//	       ./internal/pocontrol -run CloseFirst -v
package pocontrol

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// Minimal schema — only the columns execStart / execEnd / the EV marker
// touch — plus the EXCLUDE constraint verbatim from dba's migration.
const cfSchema = `
DROP SCHEMA IF EXISTS cf CASCADE;
CREATE SCHEMA cf;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE cf.production_orders (
    id_production_order bigint PRIMARY KEY,
    id_enterprise int NOT NULL,
    id_equipment int NOT NULL,
    status int NOT NULL,
    ts_start timestamptz,
    ts_end timestamptz,
    txt_production_order_notes text,
    production_final double precision
);

CREATE TABLE cf.production_orders_runtime (
    id_production_order bigint NOT NULL,
    id_equipment int NOT NULL,
    runtime_timerange tstzrange NOT NULL,
    recalc_needed boolean NOT NULL DEFAULT false,
    -- the constraint dba adds AFTER this fix ships + zombies are backfilled
    CONSTRAINT por_no_overlap
        EXCLUDE USING gist (id_equipment WITH =, runtime_timerange WITH &&)
);

CREATE TABLE cf.equipment_values (
    ts_value timestamptz NOT NULL,
    id_enterprise int, id_site int, id_area int, id_equipment int NOT NULL,
    id_production_order bigint, id_production_order_quality int, tp_equipment int,
    UNIQUE (ts_value, id_equipment)
);`

func cfConnect(t *testing.T) (context.Context, *pgxpool.Pool) {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, cfSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	return ctx, pool
}

// TestCloseFirstOnStartHealsZombie: a PO-start on an equipment that
// carries a lingering OPEN segment closes that segment at the new start
// ts, opens the new segment cleanly, leaves exactly one open segment on
// the equipment — and does NOT touch an open segment on a DIFFERENT
// equipment (the #37 concurrent-split invariant).
func TestCloseFirstOnStartHealsZombie(t *testing.T) {
	ctx, pool := cfConnect(t)

	t0 := time.Date(2026, 7, 15, 8, 0, 0, 0, time.UTC)
	t1 := t0.Add(2 * time.Hour) // the new PO-start ts

	// Seed: PO 100 finished (status=3) but left a ZOMBIE open segment on
	// equipment 10; PO 200 available on equipment 10 (the one starting);
	// PO 300 legitimately running open on equipment 11 (sibling — must
	// survive untouched).
	if _, err := pool.Exec(ctx,
		`INSERT INTO cf.production_orders (id_production_order, id_enterprise, id_equipment, status, ts_start) VALUES
		    (100, 1, 10, 3, $1), (200, 1, 10, 1, NULL), (300, 1, 11, 2, $1)`, t0); err != nil {
		t.Fatalf("seed PO: %v", err)
	}
	if _, err := pool.Exec(ctx,
		`INSERT INTO cf.production_orders_runtime (id_production_order, id_equipment, runtime_timerange) VALUES
		    (100, 10, tstzrange($1, NULL, '[)')), (300, 11, tstzrange($1, NULL, '[)'))`, t0); err != nil {
		t.Fatalf("seed runtime: %v", err)
	}

	q := 100
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 1, IDArea: 1, IDEquipment: 10, SignalQuality: &q}
	h := NewHandler(nil, slog.Default())

	// Faithful to execute(): a zombie's PO is status=3, so runningPO()
	// returns nil ⇒ a non-juggle start plan.
	plan := DecideStart(30800, 200, StatusAvailable, nil)

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// If close-first were missing/misordered, the INSERT of [t1,∞) would
	// overlap PO 100's still-open [t0,∞) and this would fail with 23P01.
	if err := h.execStart(ctx, tx, "cf", info, 200, plan, paramPayload{}, t1, t1.Add(time.Second)); err != nil {
		tx.Rollback(ctx)
		t.Fatalf("execStart raised (EXCLUDE poison not prevented?): %v", err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatalf("commit: %v", err)
	}

	// Zombie (PO 100) closed at exactly t1.
	var upper time.Time
	if err := pool.QueryRow(ctx,
		`SELECT upper(runtime_timerange) FROM cf.production_orders_runtime WHERE id_production_order=100`).
		Scan(&upper); err != nil {
		t.Fatal(err)
	}
	if !upper.Equal(t1) {
		t.Errorf("zombie not closed at start ts: upper=%v want %v", upper, t1)
	}

	// New segment (PO 200) open, and it is the ONLY open segment on eq 10.
	var openOnEq10 int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM cf.production_orders_runtime
		  WHERE id_equipment=10 AND upper(runtime_timerange) IS NULL`).Scan(&openOnEq10); err != nil {
		t.Fatal(err)
	}
	if openOnEq10 != 1 {
		t.Errorf("expected exactly 1 open segment on eq 10, got %d", openOnEq10)
	}
	var newLower time.Time
	if err := pool.QueryRow(ctx,
		`SELECT lower(runtime_timerange) FROM cf.production_orders_runtime
		  WHERE id_production_order=200 AND upper(runtime_timerange) IS NULL`).Scan(&newLower); err != nil {
		t.Fatalf("new open segment for PO 200 missing: %v", err)
	}
	if !newLower.Equal(t1) {
		t.Errorf("new segment lower=%v want %v", newLower, t1)
	}

	// Cross-equipment invariant (#37): PO 300 on eq 11 STILL OPEN.
	var siblingUpper *time.Time
	if err := pool.QueryRow(ctx,
		`SELECT upper(runtime_timerange) FROM cf.production_orders_runtime WHERE id_production_order=300`).
		Scan(&siblingUpper); err != nil {
		t.Fatal(err)
	}
	if siblingUpper != nil {
		t.Errorf("cross-equipment sibling (eq 11) was closed to %v — close-first leaked across equipments", *siblingUpper)
	}
}

// TestFinishClosesUpper: an END bounds the running segment's upper to the
// stop ts (the primary cause fix — closing on finish, not just the net).
func TestFinishClosesUpper(t *testing.T) {
	ctx, pool := cfConnect(t)

	t1 := time.Date(2026, 7, 15, 10, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Hour) // the stop ts

	if _, err := pool.Exec(ctx,
		`INSERT INTO cf.production_orders (id_production_order, id_enterprise, id_equipment, status, ts_start) VALUES
		    (200, 1, 10, 2, $1)`, t1); err != nil {
		t.Fatalf("seed PO: %v", err)
	}
	if _, err := pool.Exec(ctx,
		`INSERT INTO cf.production_orders_runtime (id_production_order, id_equipment, runtime_timerange) VALUES
		    (200, 10, tstzrange($1, NULL, '[)'))`, t1); err != nil {
		t.Fatalf("seed runtime: %v", err)
	}

	q := 100
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 1, IDArea: 1, IDEquipment: 10, SignalQuality: &q}
	h := NewHandler(nil, slog.Default())

	plan := DecideEnd(30801, &RunningPO{ID: 200, TsLower: t1})

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.execEnd(ctx, tx, "cf", info, plan, paramPayload{}, t2, t2.Add(time.Second), t2.Add(-time.Second)); err != nil {
		tx.Rollback(ctx)
		t.Fatalf("execEnd: %v", err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatalf("commit: %v", err)
	}

	var upper time.Time
	if err := pool.QueryRow(ctx,
		`SELECT upper(runtime_timerange) FROM cf.production_orders_runtime WHERE id_production_order=200`).
		Scan(&upper); err != nil {
		t.Fatal(err)
	}
	if !upper.Equal(t2) {
		t.Errorf("finish did not bound upper to ts_end: upper=%v want %v", upper, t2)
	}
	var stillOpen int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM cf.production_orders_runtime
		  WHERE id_equipment=10 AND upper(runtime_timerange) IS NULL`).Scan(&stillOpen); err != nil {
		t.Fatal(err)
	}
	if stillOpen != 0 {
		t.Errorf("segment left open after finish (zombie): %d open on eq 10", stillOpen)
	}
}
