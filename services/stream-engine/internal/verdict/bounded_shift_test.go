//go:build golden

// Task #55 acceptance: the shift rollup must be a BOUNDED, monotonic backlog
// drainer. Before the LIMIT, RunShift built its eligible set from the entire
// 30-day recalc_needed population and processed it in one all-or-nothing tx — so
// under I/O pressure the tx blew its deadline and rolled back wholesale, draining
// nothing and letting the backlog (and pre-#437 stale rows) persist forever. This
// test pins the new contract: each tick clears at most `limit` rows, OLDEST first,
// and repeated ticks converge the backlog to zero without starving on the
// every-tick reflag tail.
package verdict

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/rollup"
)

func TestBoundedShiftDrain(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set — needs ephemeral Postgres (same as -tags golden lane)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	mustExec(t, ctx, pool, schemaSQL)
	// One line (tp=3, area 10, ent 3) — eligible under the default UNION selector
	// (tp>1 outside excluded areas). A machine in a non-machine-level enterprise
	// would be provisioned but never eligible, so a line keeps the test's rows in
	// the drainable set.
	mustExec(t, ctx, pool, `INSERT INTO v3.equipments VALUES (103, 1, 10, 3, 3, NULL)`)
	mustExec(t, ctx, pool, `INSERT INTO v3.shifts VALUES (25, 'M')`)
	// 10 flagged shift rows, one per day, all OLD (2..11 days ago) so they sit
	// OUTSIDE the reflag tail [now-12h, now+18h] — the reflag must never re-queue
	// them, or the backlog could never reach zero.
	const total = 10
	mustExec(t, ctx, pool, `
		INSERT INTO v3.equipment_runtime_shift
		       (id_equipment, ts_value, ts_end, ts_value_production, id_shift, recalc_needed)
		SELECT 103,
		       now() - (g || ' days')::interval,
		       now() - (g || ' days')::interval + interval '8 hours',
		       (now() - (g || ' days')::interval)::date,
		       25, true
		  FROM generate_series(2, 11) g`)

	d := flows.Dest{Name: "test", Pool: pool, EvSchema: "v3", RefSchema: "v3"}
	exclAreas, exclEnt, machineEnt := []int{}, []int{}, []int{6}

	flagged := func() int {
		var n int
		if err := pool.QueryRow(ctx,
			`SELECT count(*) FROM v3.equipment_runtime_shift WHERE recalc_needed`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	oldestFlagged := func() time.Time {
		var ts time.Time
		if err := pool.QueryRow(ctx,
			`SELECT min(ts_value) FROM v3.equipment_runtime_shift WHERE recalc_needed`).Scan(&ts); err != nil {
			t.Fatalf("oldestFlagged (backlog may be empty): %v", err)
		}
		return ts
	}

	if got := flagged(); got != total {
		t.Fatalf("seed: got %d flagged, want %d", got, total)
	}

	const limit = 4

	// Tick 1: drains exactly `limit`, the OLDEST rows first.
	n, err := rollup.RunShift(ctx, d, exclAreas, exclEnt, machineEnt, limit, rollup.CountersAvail{}, false)
	if err != nil {
		t.Fatalf("RunShift tick1: %v", err)
	}
	if n != limit {
		t.Fatalf("tick1 drained %d, want %d (LIMIT must bound the batch)", n, limit)
	}
	if got := flagged(); got != total-limit {
		t.Fatalf("after tick1: %d flagged, want %d", got, total-limit)
	}
	afterTick1 := oldestFlagged() // the 5th-oldest row is now the frontier

	// Tick 2: drains another `limit`; the frontier must ADVANCE (oldest-first).
	n, err = rollup.RunShift(ctx, d, exclAreas, exclEnt, machineEnt, limit, rollup.CountersAvail{}, false)
	if err != nil {
		t.Fatalf("RunShift tick2: %v", err)
	}
	if n != limit {
		t.Fatalf("tick2 drained %d, want %d", n, limit)
	}
	if !oldestFlagged().After(afterTick1) {
		t.Fatalf("oldest-first violated: tick2 frontier did not advance past %v", afterTick1)
	}

	// Tick 3: only total-2*limit remain → drains the remainder, backlog → 0.
	n, err = rollup.RunShift(ctx, d, exclAreas, exclEnt, machineEnt, limit, rollup.CountersAvail{}, false)
	if err != nil {
		t.Fatalf("RunShift tick3: %v", err)
	}
	if n != total-2*limit {
		t.Fatalf("tick3 drained %d, want %d (final partial batch)", n, total-2*limit)
	}
	if got := flagged(); got != 0 {
		t.Fatalf("after tick3: %d flagged, want 0 (backlog must drain to empty)", got)
	}

	// Tick 4: empty backlog → drains 0 and stays 0 (idempotent steady state; the
	// reflag tail touches nothing because no row lives in [now-12h, now+18h]).
	n, err = rollup.RunShift(ctx, d, exclAreas, exclEnt, machineEnt, limit, rollup.CountersAvail{}, false)
	if err != nil {
		t.Fatalf("RunShift tick4: %v", err)
	}
	if n != 0 {
		t.Fatalf("tick4 drained %d on empty backlog, want 0", n)
	}
	if got := flagged(); got != 0 {
		t.Fatalf("tick4 re-flagged %d rows — reflag tail must not re-queue old rows", got)
	}
}
