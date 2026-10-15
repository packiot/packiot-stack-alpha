//go:build golden

// Golden fixture for the ENGINE form of the rollup passes (ADR-0063 A3): session
// temp tables (ON COMMIT DELETE ROWS) + a binary COPY round trip, instead of a
// CREATE TEMP TABLE … ON COMMIT DROP per transaction.
//
//   - TestGoldenEngineFormMatchesSQLForm: on the real-time cagg fixture of
//     cagg_split_golden_test.go, every pass run as caggsplit.Pass.Run (what the
//     engine executes) writes exactly what its self-contained SQL() form writes
//     (already proven equal to the original statement), in one transaction, and
//     twice in a row.
//
//   - TestGoldenEngineFormKeepsQueryID: THE pg_stat_statements property. With
//     compute_query_id on, EXPLAIN VERBOSE prints the queryid pg_stat_statements
//     would file a statement under. Over three transactions on one connection the
//     engine form's DML keeps ONE queryid; the old form (a fresh ON COMMIT DROP
//     table each transaction) gets a NEW one every transaction — the 6,245
//     calls = 1 entries that filled pg_stat_statements on staging.
//
//     DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//     go test -tags golden -run GoldenEngineForm -v ./internal/rollup/
package rollup

import (
	"context"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/caggsplit"
)

type gcsEnginePass struct {
	name string
	p    caggsplit.Pass
}

func gcsEngineHourPasses() []gcsEnginePass {
	d := gcsDest()
	return []gcsEnginePass{
		{"hour values", hourValuesPass.Map(rd(d))},
		{"hour speed", hourSpeedPass.Map(rd(d))},
		{"hour events", hourEventsPass.Map(rd(d, plannedDowntimeExpr(false)))},
		{"hour counters-avail", hourCountsAvailPass.Map(rd(d, pgIntArrayLiteral([]int{205}), 300))},
		{"hour line-lead", hourLineLeadPass.Map(func(s string) string {
			return fmtRD(withPlannedPred(s, false), d, gcsLineLeadPred, 300)
		})},
		{"hour avail-floor", hourAvailFloorPass.Map(rd(d, pgIntArrayLiteral([]int{204, 205}), 300))},
	}
}

func gcsEngineShiftPasses() []gcsEnginePass {
	d := gcsDest()
	return []gcsEnginePass{
		{"shift values", shiftValuesPass.Map(rd(d))},
		{"shift events-bank", shiftEventsPass.Map(rd(d, plannedDowntimeExpr(false)))},
		{"shift counters-avail", shiftCountsAvailPass.Map(rd(d, pgIntArrayLiteral([]int{205}), 300))},
		{"shift line-lead", shiftLineLeadPass.Map(func(s string) string {
			return fmtRD(withPlannedPred(s, false), d, gcsLineLeadPred, 300)
		})},
		{"shift avail-floor", shiftAvailFloorPass.Map(rd(d, pgIntArrayLiteral([]int{204, 205}), 300))},
	}
}

func TestGoldenEngineFormMatchesSQLForm(t *testing.T) {
	pool := gcsPool(t)
	setupGCS(t, pool)
	ctx := context.Background()
	d := gcsDest()
	for _, grain := range []struct {
		name, table, eligTable, elig string
		args                         []any
		passes                       []gcsEnginePass
		after                        map[string]string // plain statements the engine runs after a pass
	}{
		{"hour", "equipment_oee_hourly", "hour_elig", fmtRD(hourEligibleSQL, d), []any{[]int{}, []int{}}, gcsEngineHourPasses(), nil},
		{"shift", "equipment_oee_shift", "shift_elig", fmtRD(shiftEligibleSQL, d, 1000), []any{[]int{}, []int{}, []int{}}, gcsEngineShiftPasses(),
			map[string]string{"shift events-bank": fmtRD(shiftEventsUpdateSQL, d)}},
	} {
		t.Run(grain.name, func(t *testing.T) {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(ctx) //nolint:errcheck
			// the engine's eligible set: a session table filled by INSERT
			n, err := fillElig(ctx, tx, grain.eligTable, grain.elig, grain.args...)
			if err != nil {
				t.Fatal(err)
			}
			if n == 0 {
				t.Fatal("empty eligible set")
			}
			for _, ep := range grain.passes {
				gcsExec(t, ctx, tx, "savepoint", "SAVEPOINT eng")
				gcsExec(t, ctx, tx, ep.name+" (sql form)", ep.p.SQL())
				want := gcsDump(t, ctx, tx, grain.table)
				var wantSnap []string
				if ep.p.Apply == "" { // snapshot-only (shift_ev): compare the snapshot itself
					wantSnap = gcsDumpAny(t, ctx, tx, ep.p.Table)
				}
				gcsExec(t, ctx, tx, "rollback to savepoint", "ROLLBACK TO SAVEPOINT eng")
				for run := 1; run <= 2; run++ {
					if _, err := ep.p.Run(ctx, tx); err != nil {
						t.Fatalf("%s (engine form, run %d): %v", ep.name, run, err)
					}
				}
				got := gcsDump(t, ctx, tx, grain.table)
				ulps := 0
				for i := range want {
					if i >= len(got) || !gcsSame(got[i], want[i], &ulps) {
						t.Errorf("%s: engine form differs from the SQL form", ep.name)
						break
					}
				}
				if wantSnap != nil {
					if gotSnap := gcsDumpAny(t, ctx, tx, ep.p.Table); strings.Join(gotSnap, "\n") != strings.Join(wantSnap, "\n") {
						t.Errorf("%s: snapshot rows differ (%d vs %d)", ep.name, len(gotSnap), len(wantSnap))
					}
				}
				t.Logf("%s: engine form == SQL form (%d rows, %d last-ulp float differences)", ep.name, len(got), ulps)
				if after, ok := grain.after[ep.name]; ok {
					gcsExec(t, ctx, tx, "after "+ep.name, after)
				}
			}
		})
	}
}

// gcsDumpAny dumps any (temp) table as sorted jsonb rows.
func gcsDumpAny(t *testing.T, ctx context.Context, tx pgx.Tx, table string) []string {
	t.Helper()
	rows, err := tx.Query(ctx, `SELECT to_jsonb(t)::text AS j FROM `+table+` t ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return out
}

var queryIdentifier = regexp.MustCompile(`Query Identifier: (-?[0-9]+)`)

func TestGoldenEngineFormKeepsQueryID(t *testing.T) {
	pool := gcsPool(t)
	setupGCS(t, pool)
	ctx := context.Background()
	d := gcsDest()
	conn, err := pool.Acquire(ctx) // ONE backend, as a dedicated pool gives the job
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SET compute_query_id = on`); err != nil {
		t.Fatal(err)
	}
	explainID := func(tx pgx.Tx, sql string) string {
		t.Helper()
		rows, err := tx.Query(ctx, "EXPLAIN (VERBOSE) "+sql)
		if err != nil {
			t.Fatalf("explain: %v", err)
		}
		lines, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		m := queryIdentifier.FindStringSubmatch(strings.Join(lines, "\n"))
		if m == nil {
			t.Fatal("EXPLAIN VERBOSE printed no Query Identifier (compute_query_id off?)")
		}
		return m[1]
	}
	values := hourValuesPass.Map(rd(d))
	// the old form under its own names, so it never drops the engine's session tables
	old := caggsplit.Statements(strings.NewReplacer("hour_vals_snap", "old_vals_snap", "hour_elig", "old_elig").
		Replace(fmtRD(hourValuesSplitSQL, d)))
	var engineIDs, oldIDs []string
	for tick := 0; tick < 3; tick++ {
		tx, err := conn.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		// engine form
		if _, err := fillElig(ctx, tx, "hour_elig", fmtRD(hourEligibleSQL, d), []int{}, []int{}); err != nil {
			t.Fatal(err)
		}
		if err := caggsplit.Snapshot(ctx, tx, values.Table, values.Read); err != nil {
			t.Fatal(err)
		}
		engineIDs = append(engineIDs, explainID(tx, values.Apply))
		// the old form: a fresh table per transaction (DROP + CREATE … ON COMMIT DROP AS)
		if _, err := tx.Exec(ctx, `DROP TABLE IF EXISTS pg_temp.old_elig; CREATE TEMP TABLE old_elig ON COMMIT DROP AS SELECT * FROM hour_elig`); err != nil {
			t.Fatal(err)
		}
		for _, st := range old[:2] {
			if _, err := tx.Exec(ctx, st); err != nil {
				t.Fatal(err)
			}
		}
		oldIDs = append(oldIDs, explainID(tx, old[2]))
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	t.Logf("engine form queryids: %v; old form: %v", engineIDs, oldIDs)
	if engineIDs[0] != engineIDs[1] || engineIDs[1] != engineIDs[2] {
		t.Errorf("the engine form's DML changed queryid between transactions on one backend: %v", engineIDs)
	}
	if oldIDs[0] == oldIDs[1] || oldIDs[1] == oldIDs[2] {
		t.Errorf("the old per-transaction temp table kept its queryid (%v) — the premise changed; re-check", oldIDs)
	}
}
