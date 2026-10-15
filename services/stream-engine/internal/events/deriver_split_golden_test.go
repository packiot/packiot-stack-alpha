//go:build golden

// Golden fixture for the native events deriver's read/apply split (ADR-0063 A2):
// on a REAL real-time ca_discrete_changes_1s cagg, the correct (DELETE) and
// upsert (INSERT … ON CONFLICT) passes write exactly what the single statements
// wrote — same transaction, same now(), same deleted/upserted counts — the split
// reads plan with a constant watermark, and the originals still show the trap.
// They run with bind arguments over the simple protocol, as RunOnce runs them.
//
//	DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//	go test -tags golden -run GoldenDeriverSplit -v ./internal/events/
package events

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/caggsplit"
)

func TestGoldenDeriverSplit(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	pc, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol // as internal/db/pool.go
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	const s = "gds"
	for _, q := range []string{
		`CREATE EXTENSION IF NOT EXISTS timescaledb`,
		`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`,
		`CREATE SCHEMA ` + s,
		`CREATE TABLE ` + s + `.equipments (id_equipment int PRIMARY KEY, id_area int, id_enterprise int, tp_equipment int, status_type int)`,
		// 1-3 native state machines (status_type 4); 4 a wide-row machine of enterprise 8
		// (opted in via $3); 5 excluded by area; 6 not a state equipment.
		`INSERT INTO ` + s + `.equipments VALUES (1,10,3,1,4),(2,10,3,1,4),(3,10,3,3,4),(4,10,8,1,0),(5,99,3,1,4),(6,10,3,1,0)`,
		`CREATE TABLE ` + s + `.discrete (ts_value timestamptz NOT NULL, id_equipment int, id_enterprise int, state int)`,
		`SELECT create_hypertable('` + s + `.discrete', 'ts_value', chunk_time_interval => interval '4 hours')`,
		// a state sample every 20 s for 26 h; states change in runs of a few minutes,
		// and some samples carry no state (the fill logic carries the last one).
		`INSERT INTO ` + s + `.discrete
		   SELECT m, e, CASE WHEN e = 4 THEN 8 ELSE 3 END,
		          CASE WHEN (extract(epoch FROM m)::bigint / 20 + e) % 13 = 0 THEN NULL
		               ELSE (ARRAY[6, 6, 6, 5, 6, 10, 6, 11])[1 + ((extract(epoch FROM m)::bigint / (240 + 60 * e)) % 8)::int] END
		     FROM generate_series(1, 6) e,
		          generate_series(date_trunc('minute', now()) - interval '26 hours', now() - interval '5 seconds', interval '20 seconds') m`,
		`CREATE MATERIALIZED VIEW ` + s + `.ca_discrete_changes_1s
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 second', ts_value) AS ts_value, id_equipment, id_enterprise, max(state) AS state
		   FROM ` + s + `.discrete GROUP BY 1, 2, 3 WITH NO DATA`,
		`CALL refresh_continuous_aggregate('` + s + `.ca_discrete_changes_1s', NULL, date_trunc('hour', now()) - interval '2 hours')`,
		`ANALYZE ` + s + `.discrete`,
		`CREATE TABLE ` + s + `.equipment_events (ts_event timestamptz, ts_end timestamptz, id_equipment int, status int,
		    id_enterprise int, duration numeric, forced_creation_system boolean NOT NULL DEFAULT false,
		    PRIMARY KEY (id_equipment, ts_event))`,
		// stale rows the correct pass must delete (no matching transition), one it must
		// keep (forced by the system), and one matching row with a wrong ts_end the
		// upsert must fix.
		`INSERT INTO ` + s + `.equipment_events (ts_event, ts_end, id_equipment, status, id_enterprise, duration, forced_creation_system) VALUES
		    (now() - interval '3 hours 7 seconds', NULL, 1, 10, 3, 0, false),
		    (now() - interval '2 hours 3 seconds', NULL, 2, 5, 3, 0, false),
		    (now() - interval '90 minutes', NULL, 3, 11, 3, 0, true)`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("setup %q: %v", q[:min(len(q), 80)], err)
		}
	}
	render := func(tpl string) string { return fmt.Sprintf(tpl, s, s, s) }
	args := []any{[]int{99}, []int{}, []int{8}}
	dump := func(tx pgx.Tx) []string {
		rows, err := tx.Query(ctx, `SELECT t::text FROM `+s+`.equipment_events t ORDER BY id_equipment, ts_event`)
		if err != nil {
			t.Fatal(err)
		}
		out, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	run := func(correct, upsert string) (del, ups int64, rows []string) {
		t.Helper()
		if _, err := tx.Exec(ctx, "SAVEPOINT d"); err != nil {
			t.Fatal(err)
		}
		dt, err := tx.Exec(ctx, render(correct), args...)
		if err != nil {
			t.Fatalf("correct: %v", err)
		}
		ut, err := tx.Exec(ctx, render(upsert), args...)
		if err != nil {
			t.Fatalf("upsert: %v", err)
		}
		rows = dump(tx)
		if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT d"); err != nil {
			t.Fatal(err)
		}
		return dt.RowsAffected(), ut.RowsAffected(), rows
	}
	wantDel, wantUps, want := run(correctSQL, upsertSQL)
	gotDel, gotUps, got := run(correctSplitSQL, upsertSplitSQL)

	// the ENGINE form (ADR-0063 A3): the passes RunOnce runs — session snapshot
	// tables + binary COPY, scope arrays inlined — delete/upsert the same rows.
	d := Dest{EvSchema: s, RefSchema: s, SilverSchema: s}
	engine := func(p caggsplit.Pass) int64 {
		t.Helper()
		rp, err := deriverPassFor(d, p, []int{99}, []int{}, []int{8})
		if err != nil {
			t.Fatal(err)
		}
		tag, err := rp.Run(ctx, tx)
		if err != nil {
			t.Fatalf("engine form %s: %v", p.Table, err)
		}
		return tag.RowsAffected()
	}
	if _, err := tx.Exec(ctx, "SAVEPOINT e"); err != nil {
		t.Fatal(err)
	}
	engDel, engUps := engine(correctPass), engine(upsertPass)
	if engRows := dump(tx); engDel != wantDel || engUps != wantUps || !reflect.DeepEqual(engRows, want) {
		t.Errorf("engine form differs: deleted %d upserted %d (%d events) vs inline %d / %d (%d events)",
			engDel, engUps, len(engRows), wantDel, wantUps, len(want))
	}
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT e"); err != nil {
		t.Fatal(err)
	}
	t.Logf("inline: deleted %d, upserted %d, %d events; split: deleted %d, upserted %d, %d events",
		wantDel, wantUps, len(want), gotDel, gotUps, len(got))
	if wantDel == 0 || wantUps == 0 {
		t.Fatalf("the fixture exercises nothing (deleted %d, upserted %d)", wantDel, wantUps)
	}
	if gotDel != wantDel || gotUps != wantUps {
		t.Errorf("row counts differ: split deleted %d upserted %d, inline %d / %d", gotDel, gotUps, wantDel, wantUps)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("split differs from inline (%d vs %d events)", len(got), len(want))
		for i := range want {
			if i < len(got) && got[i] != want[i] {
				t.Errorf(" got  %s\n want %s", got[i], want[i])
				break
			}
		}
	}

	explain := func(sql string) string {
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
	for _, c := range []struct{ name, inline, split string }{
		{"correct", correctSQL, correctSplitSQL}, {"upsert", upsertSQL, upsertSplitSQL},
	} {
		if !strings.Contains(explain(render(c.inline)), "cagg_watermark") {
			t.Fatalf("%s: the original no longer shows an unconstified cagg_watermark() — re-check the premise", c.name)
		}
		st := caggsplit.Statements(render(c.split))
		if len(st) != 3 {
			t.Fatalf("%s: want 3 statements, got %d", c.name, len(st))
		}
		if p := explain(st[1]); strings.Contains(p, "cagg_watermark") {
			t.Errorf("%s: the split read plans with an unconstified watermark:\n%s", c.name, p)
		}
		if strings.Contains(st[2], "ca_discrete_changes_1s") {
			t.Errorf("%s: the apply reads the cagg", c.name)
		}
	}
}
