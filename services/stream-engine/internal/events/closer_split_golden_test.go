//go:build golden

// Golden fixture for the stale-open closer's read/apply split (ADR-0063 Phase A2,
// 2026-10-14). It runs against a REAL TimescaleDB with a REAL real-time
// continuous aggregate, because the bug is in how TimescaleDB plans that cagg:
//
//   - TestGoldenCloserCaggReadIsPlannedAsSelect: every statement RunOnceClose
//     sends that reads equipment_categorical_1min must plan with a CONSTANT
//     watermark. TimescaleDB constifies it only for a SELECT; inside the old
//     single-statement UPDATE it stays a runtime cagg_watermark() call (staging:
//     raw tail priced at 458 M rows, then a merge join over every
//     equipment_events chunk; 19.8 s mean, 15 % of all DB time). The test also
//     EXPLAINs the old statement and requires the trap to be visible there, so
//     it fails on the old code and cannot pass vacuously.
//
//   - TestGoldenCloserSnapshotMatchesInline: same fixture, same transaction (so
//     the same now()), old single statement vs read + apply. The resulting
//     table must be identical row for row: a non-latest open bounded by its
//     successor, a silent trailing RUN closed at last count + threshold, an
//     open STOP left open, a zero-length row rebound, a human-justified
//     trailing RUN left open, a row outside the horizon, an equipment with no
//     productive minute, and another tenant.
//
//     DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//     go test -tags golden -run GoldenCloser -v ./internal/events/
package events

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const goldenCloserTS = "gclts"

// setupGoldenCloserTS: equipments, a raw equipment_values hypertable (12 h
// chunks, 10 days of history), a real-time 1-minute cagg materialized up to
// now()-3 h (so its read splits into materialized + raw tail), and the events.
func setupGoldenCloserTS(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	s := goldenCloserTS
	for _, q := range []string{
		`CREATE EXTENSION IF NOT EXISTS timescaledb`,
		`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`,
		`CREATE SCHEMA ` + s,
		`CREATE TABLE ` + s + `.equipments (id_equipment int PRIMARY KEY, id_enterprise int, tp_equipment int,
		    status_type int, stop_threshold_time int)`,
		// ent 7 in scope (1–8); 9 is another tenant (ent 8)
		`INSERT INTO ` + s + `.equipments VALUES (1,7,1,0,300),(2,7,1,0,300),(3,7,1,0,NULL),(4,7,3,0,600),
		    (5,7,1,0,300),(6,7,1,0,300),(7,7,1,0,300),(8,7,1,0,300),(9,8,1,0,300)`,
		`CREATE TABLE ` + s + `.equipment_values (ts_value timestamptz NOT NULL, id_equipment int,
		    gross_production_incr float8)`,
		`SELECT create_hypertable('` + s + `.equipment_values', 'ts_value', chunk_time_interval => interval '12 hours')`,
		// every equipment except 8 produces each minute until (its id × 7) minutes ago; a 20-minute
		// gap two hours ago; equipment 8 never produces
		`INSERT INTO ` + s + `.equipment_values
		   SELECT m, e, CASE WHEN m BETWEEN now() - interval '130 minutes' AND now() - interval '110 minutes' THEN 0 ELSE 1 END
		     FROM generate_series(1, 9) e,
		          generate_series(date_trunc('minute', now()) - interval '10 days', date_trunc('minute', now()) - interval '1 minute', interval '1 minute') m
		    WHERE e <> 8 AND m < now() - make_interval(mins => e * 7)`,
		`CREATE MATERIALIZED VIEW ` + s + `.equipment_categorical_1min
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 minute', ts_value) AS ts_value, id_equipment,
		        sum(gross_production_incr) AS gross_production_incr
		   FROM ` + s + `.equipment_values GROUP BY 1, 2 WITH NO DATA`,
		`CALL refresh_continuous_aggregate('` + s + `.equipment_categorical_1min', NULL, date_trunc('hour', now()) - interval '3 hours')`,
		`ANALYZE ` + s + `.equipment_values`,
		`CREATE TABLE ` + s + `.equipment_events (id_equipment_event bigint, id_equipment int, ts_event timestamptz,
		    ts_end timestamptz, duration int, status int, last_update timestamptz,
		    cd_category text, cd_subcategory text, cd_machine text, txt_downtime_notes text,
		    planned_downtime boolean, change_over boolean, idle boolean,
		    PRIMARY KEY (id_equipment, ts_event))`,
		`INSERT INTO ` + s + `.equipment_events (id_equipment_event, id_equipment, ts_event, ts_end, status, cd_category) VALUES
		   -- 1: STOP followed by a RUN, both open → the stop is bounded at the run's start;
		   --    the trailing RUN (counts silent since 7 min) is closed at last count + 300 s
		   (11, 1, now() - interval '50 minutes', NULL, 10, NULL), (12, 1, now() - interval '30 minutes', NULL, 6, NULL),
		   -- 2: trailing open STOP after the last count → stays open
		   (21, 2, now() - interval '10 minutes', NULL, 10, NULL),
		   -- 3: trailing RUN, default threshold (NULL → $2)
		   (31, 3, now() - interval '90 minutes', NULL, 6, NULL),
		   -- 4: line, 600 s threshold; RUN closed zero-length at its own start, successor later → rebound
		   (41, 4, now() - interval '70 minutes', now() - interval '70 minutes', 6, NULL),
		   (42, 4, now() - interval '45 minutes', NULL, 10, NULL),
		   -- 5: operator-justified trailing RUN → left open (human guard)
		   (51, 5, now() - interval '80 minutes', NULL, 6, 'PRG-01'),
		   -- 6: open STOP 5 days ago with a successor 4 days ago → outside the 72 h horizon (main pass ignores it)
		   (61, 6, now() - interval '5 days', NULL, 10, NULL), (62, 6, now() - interval '4 days', now() - interval '4 days' + interval '1 hour', 6, NULL),
		   -- 7: open STOP followed by an open STOP inside the horizon
		   (71, 7, now() - interval '40 hours', NULL, 10, NULL), (72, 7, now() - interval '39 hours', NULL, 10, NULL),
		   -- 8: no productive minute at all → trailing RUN cannot be closed by silence
		   (81, 8, now() - interval '60 minutes', NULL, 6, NULL),
		   -- 9: another tenant → untouched
		   (91, 9, now() - interval '60 minutes', NULL, 6, NULL)`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("setup %q: %v", q, err)
		}
	}
}

func goldenCloserDest(pool *pgxpool.Pool) Dest {
	return Dest{Name: "golden", Pool: pool, SilverSchema: goldenCloserTS, RefSchema: goldenCloserTS}
}

var goldenCloserCfg = CloserConfig{Enterprises: []int{7}, ThresholdDefSec: 300, HorizonHours: 72, LongHorizonDays: 60}

func goldenCloserDump(t *testing.T, ctx context.Context, tx pgx.Tx) []string {
	t.Helper()
	rows, err := tx.Query(ctx, `SELECT concat_ws('|', id_equipment, id_equipment_event, ts_event, ts_end, duration, status, cd_category)
	                              FROM `+goldenCloserTS+`.equipment_events ORDER BY id_equipment, ts_event`)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func goldenExplain(t *testing.T, ctx context.Context, pool *pgxpool.Pool, sql string, args ...any) string {
	t.Helper()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // plan only
	rows, err := tx.Query(ctx, "EXPLAIN "+sql, args...)
	if err != nil {
		t.Fatalf("explain: %v", err)
	}
	lines, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return strings.Join(lines, "\n")
}

func TestGoldenCloserCaggReadIsPlannedAsSelect(t *testing.T) {
	rec := &sqlRecorder{}
	pool := goldenCPACPool(t, rec)
	setupGoldenCloserTS(t, pool)
	ctx := context.Background()
	plain := goldenCPACPool(t, nil)

	// The trap must be visible on the old single statement, or this test proves nothing.
	old := fmt.Sprintf(closeStaleOpensSQL, goldenCloserTS, goldenCloserTS, "", "ev", "")
	if p := goldenExplain(t, ctx, plain, old, goldenCloserCfg.Enterprises, 300, 72); !strings.Contains(p, "cagg_watermark") {
		t.Fatal("the single-statement UPDATE no longer shows an unconstified cagg_watermark() — this TimescaleDB " +
			"constifies DML too; re-check the premise before trusting this test")
	}

	rec.mu.Lock()
	rec.stmt = nil
	rec.mu.Unlock()
	start := time.Now()
	if _, err := RunOnceClose(ctx, goldenCloserDest(pool), goldenCloserCfg); err != nil {
		t.Fatal(err)
	}
	t.Logf("RunOnceClose: %s", time.Since(start))

	readers := 0
	for _, st := range rec.stmt {
		if !strings.Contains(st.sql, "equipment_categorical_1min") {
			continue
		}
		readers++
		if p := goldenExplain(t, ctx, plain, st.sql, st.args...); strings.Contains(p, "cagg_watermark") {
			head := strings.TrimSpace(st.sql)
			if i := strings.LastIndex(head, "\nUPDATE"); i >= 0 {
				head = head[i:]
			}
			if len(head) > 60 {
				head = head[:60]
			}
			t.Errorf("a closer statement reads the real-time cagg with an UNCONSTIFIED watermark (planned as DML): %q…",
				strings.TrimSpace(head))
		}
	}
	if readers == 0 {
		t.Fatal("no recorded statement read equipment_categorical_1min — the test proves nothing")
	}
}

func TestGoldenCloserSnapshotMatchesInline(t *testing.T) {
	pool := goldenCPACPool(t, nil)
	setupGoldenCloserTS(t, pool)
	ctx := context.Background()
	d := goldenCloserDest(pool)

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	before := goldenCloserDump(t, ctx, tx)
	if _, err := tx.Exec(ctx, "SAVEPOINT inline"); err != nil {
		t.Fatal(err)
	}
	t0 := time.Now()
	inlineTag, err := tx.Exec(ctx, fmt.Sprintf(closeStaleOpensSQL, d.SilverSchema, d.RefSchema, "", "ev", ""),
		goldenCloserCfg.Enterprises, 300, 72)
	if err != nil {
		t.Fatal(err)
	}
	tInline := time.Since(t0)
	want := goldenCloserDump(t, ctx, tx)
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT inline"); err != nil {
		t.Fatal(err)
	}
	t0 = time.Now()
	tag, err := runCloseMain(ctx, tx, d, goldenCloserCfg.Enterprises, 300, 72)
	if err != nil {
		t.Fatal(err)
	}
	tSplit := time.Since(t0)
	got := goldenCloserDump(t, ctx, tx)
	t.Logf("inline %s (%d rows), read+apply %s (%d rows)", tInline, inlineTag.RowsAffected(), tSplit, tag.RowsAffected())

	if inlineTag.RowsAffected() < 4 {
		t.Fatalf("fixture must exercise several closes (inline closed %d)", inlineTag.RowsAffected())
	}
	if reflect.DeepEqual(before, want) {
		t.Fatal("the inline pass changed nothing — the comparison proves nothing")
	}
	if tag.RowsAffected() != inlineTag.RowsAffected() {
		t.Errorf("rows closed: read+apply %d, inline %d", tag.RowsAffected(), inlineTag.RowsAffected())
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("read+apply differs from the inline statement: %d vs %d rows", len(got), len(want))
		wantSet := map[string]bool{}
		for _, r := range want {
			wantSet[r] = true
		}
		gotSet := map[string]bool{}
		for _, r := range got {
			gotSet[r] = true
			if !wantSet[r] {
				t.Errorf("  only in read+apply: %s", r)
			}
		}
		for _, r := range want {
			if !gotSet[r] {
				t.Errorf("  only in inline:     %s", r)
			}
		}
	}
}
