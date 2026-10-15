//go:build golden

// Golden fixture for the progress-safe shift batch (batch.go): a large backlog
// whose per-batch cost exceeds the budget at the configured LIMIT must still
// drain — every tick finishes within its budget and every tick after the first
// commits a batch.
//
// The cost is made deterministic with shiftBatchHook: pg_sleep proportional to
// the batch size (2 ms per row) inside the shift transaction, so a 1,000-row batch
// costs > 2 s against a 2 s budget and a 500-row batch fits. The control run
// (fixed LIMIT, the pre-fix behaviour) shows the failure: every tick runs out of
// budget, rolls back, and the backlog never moves.
//
//	DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//	go test -tags golden -run GoldenShiftBacklog -v ./internal/rollup/
package rollup

import (
	"context"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

const (
	backlogLines    = 40
	backlogShifts   = 75 // per line
	backlogLimit    = 1000
	backlogBudget   = 2 * time.Second
	backlogRowDelay = 0.002 // seconds of pg_sleep per batch row
)

func backlogPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	pc, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol // as internal/db/pool.go
	pc.ConnConfig.RuntimeParams["search_path"] = "golden,public"         // the fixture's piot_* stubs
	pool, err := pgxpool.NewWithConfig(context.Background(), pc)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func setupBacklog(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	fixture := `
		INSERT INTO golden.equipments SELECT 500 + i, 1, 1, 35, 3, 100 FROM generate_series(1, 40) i;
		INSERT INTO golden.shifts VALUES (1,'S1');
		-- 8-hour shifts over 25 days for 40 lines, all flagged and never computed: a
		-- backlog of 3,000 rows (a replay, a manual reflag, a long engine outage).
		INSERT INTO golden.equipment_oee_shift
		    (id_equipment, ts_value, ts_end, ts_value_production, id_shift, recalc_needed, computed_at)
		SELECT 500 + i, b, b + interval '8 hours', date_trunc('day', b), 1, true, NULL
		  FROM generate_series(1, 40) i,
		       -- 75 shifts per line ending 13 h ago at the latest: all outside the
		       -- 12 h reflag window and inside the 30-day eligible window, whatever
		       -- the time of day
		       LATERAL (SELECT date_trunc('hour', now()) - interval '13 hours' - (k - 1) * interval '8 hours' AS b
		                  FROM generate_series(1, 75) k) s;`
	for _, s := range []string{goldenSchema, shiftGoldenSchema, fixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	if n := backlogCount(t, pool); n != backlogLines*backlogShifts {
		t.Fatalf("fixture backlog = %d, want %d", n, backlogLines*backlogShifts)
	}
}

// backlogCount: flagged rows outside the reflag window (RunShift re-flags the last
// 12 h every tick, so only older rows measure the drain).
func backlogCount(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM golden.equipment_oee_shift WHERE recalc_needed AND ts_value < now() - interval '12 hours'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func backlogDest(pool *pgxpool.Pool) flows.Dest {
	return flows.Dest{Name: "golden-backlog", Pool: pool, EvSchema: "golden", RefSchema: "golden", SilverSchema: "golden",
		GoldSchema: "golden", GrainSchema: "golden", ConfigSchema: "golden"}
}

func withCostPerRow(t *testing.T) {
	t.Helper()
	shiftBatchHook = func(ctx context.Context, tx pgx.Tx, n int64) error {
		_, err := tx.Exec(ctx, `SELECT pg_sleep($1)`, float64(n)*backlogRowDelay)
		return err
	}
	t.Cleanup(func() { shiftBatchHook = nil })
}

// shiftTick is one runtime-rollup tick's shift step, exactly as LoopGrains runs it.
func shiftTick(ctx context.Context, d flows.Dest, sz *batchSizer, logger *slog.Logger) (limit int, n int64, over bool, err error) {
	return runAdaptive(ctx, sz, d.Name, backlogBudget, logger, func(c context.Context, limit int) (int64, error) {
		return RunShift(c, d, []int{}, []int{}, []int{}, limit, CountersAvail{}, false)
	})
}

func TestGoldenShiftBacklogDrainsWithinBudget(t *testing.T) {
	pool := backlogPool(t)
	setupBacklog(t, pool)
	withCostPerRow(t)
	ctx := context.Background()
	d := backlogDest(pool)
	sz := newBatchSizer("test-shift", backlogLimit)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	prev := backlogCount(t, pool)
	for tick := 1; prev > 0; tick++ {
		if tick > 20 {
			t.Fatalf("backlog not drained after 20 ticks (%d rows left)", prev)
		}
		start := time.Now()
		limit, n, over, err := shiftTick(ctx, d, sz, logger)
		elapsed := time.Since(start)
		left := backlogCount(t, pool)
		t.Logf("tick %2d: batch %4d → processed %4d, over budget %-5v, %6.2fs, backlog %4d", tick, limit, n, over, elapsed.Seconds(), left)
		if err != nil && !over {
			t.Fatalf("tick %d: %v", tick, err)
		}
		// THE BOUND: no tick outlives its budget (plus slack for the cancel round trip).
		if elapsed > backlogBudget+time.Second {
			t.Errorf("tick %d took %s, budget %s", tick, elapsed, backlogBudget)
		}
		switch {
		case over:
			if left != prev {
				t.Errorf("tick %d ran out of budget but the backlog moved %d → %d (a partial commit)", tick, prev, left)
			}
			if tick > 1 {
				t.Errorf("tick %d: only the first tick may overrun (the batch is halved after it)", tick)
			}
		default:
			// PROGRESS: every committed tick drains its whole batch.
			if left >= prev {
				t.Errorf("tick %d committed but the backlog did not shrink (%d → %d)", tick, prev, left)
			}
		}
		prev = left
	}
}

// The pre-fix behaviour: a fixed LIMIT whose batch costs more than the budget
// rolls back every tick and never drains anything.
func TestGoldenShiftBacklogFixedLimitNeverDrains(t *testing.T) {
	pool := backlogPool(t)
	setupBacklog(t, pool)
	withCostPerRow(t)
	ctx := context.Background()
	d := backlogDest(pool)
	start := backlogCount(t, pool)
	for tick := 1; tick <= 3; tick++ {
		_, _, over, _ := runBudgeted(ctx, backlogBudget, func(c context.Context) (int64, error) {
			return RunShift(c, d, []int{}, []int{}, []int{}, backlogLimit, CountersAvail{}, false)
		})
		if !over {
			t.Fatalf("tick %d: a %d-row batch fit the budget — the fixture no longer models the failure", tick, backlogLimit)
		}
	}
	if left := backlogCount(t, pool); left != start {
		t.Fatalf("fixed-limit ticks changed the backlog %d → %d; expected no progress at all", start, left)
	}
}
