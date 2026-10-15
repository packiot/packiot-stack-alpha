//go:build golden

// Golden fixture for the uns equipment refresher's read/apply split (ADR-0063
// A2): on a REAL real-time agg_equipment_values_1hour cagg, the split form
// writes exactly what the single UPDATE wrote (same transaction, same now()), its
// read plans with a constant watermark, and the original still shows the trap.
// The split runs with bind arguments over the simple protocol — exactly how
// RefreshEquipment executes it — so the multi-statement + arguments path is
// covered too.
//
//	DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//	go test -tags golden -run GoldenUnsRefreshSplit -v ./internal/uns/
package uns

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/caggsplit"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

func TestGoldenUnsRefreshSplit(t *testing.T) {
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
	const s = "gus"
	for _, q := range []string{
		`CREATE EXTENSION IF NOT EXISTS timescaledb`,
		`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`,
		`CREATE SCHEMA ` + s,
		`CREATE TABLE ` + s + `.equipments (id_equipment int PRIMARY KEY, id_area int, id_enterprise int, tp_equipment int)`,
		// 1-3 lines, 4 a line in an excluded area, 5 a machine (tp 1: not refreshed)
		`INSERT INTO ` + s + `.equipments VALUES (1,10,3,3),(2,10,3,3),(3,11,5,2),(4,99,3,3),(5,10,3,1)`,
		`CREATE TABLE ` + s + `.equipment_values (ts_value timestamptz NOT NULL, id_equipment int,
		    net_production_incr float8, gross_production_incr float8, scrap_incr float8, speed float8)`,
		`SELECT create_hypertable('` + s + `.equipment_values', 'ts_value', chunk_time_interval => interval '1 day')`,
		// 40 days of minutes (covers this month and the previous one, whatever the date)
		`INSERT INTO ` + s + `.equipment_values
		   SELECT m, e, 2 + e % 3 + (extract(minute FROM m)::int % 4), 3 + e % 3 + (extract(minute FROM m)::int % 4),
		          (extract(minute FROM m)::int % 9 = 0)::int, 30 + e + extract(minute FROM m)::int % 7
		     FROM generate_series(1, 5) e,
		          generate_series(date_trunc('minute', now()) - interval '40 days', date_trunc('minute', now()) - interval '1 minute', interval '5 minutes') m`,
		`CREATE MATERIALIZED VIEW ` + s + `.agg_equipment_values_1hour
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 hour', ts_value) AS ts_value, id_equipment,
		        sum(net_production_incr) AS net_production_incr, sum(gross_production_incr) AS gross_production_incr,
		        sum(scrap_incr) AS scrap_incr, avg(speed) AS speed
		   FROM ` + s + `.equipment_values GROUP BY 1, 2 WITH NO DATA`,
		`CALL refresh_continuous_aggregate('` + s + `.agg_equipment_values_1hour', NULL, date_trunc('hour', now()) - interval '5 hours')`,
		`ANALYZE ` + s + `.equipment_values`,
		`CREATE TABLE ` + s + `.equipment_live_month (id_equipment int PRIMARY KEY, gross_production float8, net_production float8,
		    scrap float8, speed float8, begin_time date, end_time timestamp, last_updated timestamptz)`,
		`INSERT INTO ` + s + `.equipment_live_month (id_equipment) SELECT id_equipment FROM ` + s + `.equipments`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("setup %q: %v", q[:min(len(q), 80)], err)
		}
	}
	g := equipmentGrains[0]
	render := func(tpl string) string { return fmt.Sprintf(tpl, s, s, g.grain, g.unsTable, g.span, s) }
	inline, split := render(refreshEquipmentSQL), render(refreshEquipmentSplitSQL)
	args := []any{[]int{99}, []int{}} // exclude area 99

	dump := func(tx pgx.Tx) []string {
		rows, err := tx.Query(ctx, `SELECT to_jsonb(t)::text FROM `+s+`.equipment_live_month t ORDER BY id_equipment`)
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
	before := dump(tx)
	if _, err := tx.Exec(ctx, "SAVEPOINT a"); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, inline, args...); err != nil {
		t.Fatalf("inline: %v", err)
	}
	want := dump(tx)
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT a"); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, split, args...); err != nil {
		t.Fatalf("split: %v", err)
	}
	got := dump(tx)
	if reflect.DeepEqual(before, want) {
		t.Fatal("the inline refresh changed nothing — the comparison proves nothing")
	}
	if !sameRows(got, want) {
		t.Errorf("split differs from inline:\n got  %v\n want %v", got, want)
	}
	t.Logf("%d rows; e.g. %s", len(got), got[0])

	// the ENGINE form (ADR-0063 A3): the pass RefreshEquipment runs — session
	// snapshot table + binary COPY, arrays inlined — writes the same rows.
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT a"); err != nil {
		t.Fatal(err)
	}
	d := flows.Dest{EvSchema: s, RefSchema: s, GrainSchema: s}
	p, err := refreshEquipmentPassFor(d, g.grain, g.unsTable, g.span, []int{99}, []int{})
	if err != nil {
		t.Fatal(err)
	}
	for run := 1; run <= 2; run++ {
		if _, err := p.Run(ctx, tx); err != nil {
			t.Fatalf("engine form run %d: %v", run, err)
		}
	}
	if engine := dump(tx); !sameRows(engine, want) {
		t.Errorf("engine form differs from inline:\n got  %v\n want %v", engine, want)
	}
	if strings.Contains(p.Read, "$") || strings.Contains(p.Apply, "$") {
		t.Errorf("engine form still carries bind parameters (COPY takes none)")
	}

	// plans: the original trips the watermark trap, the split read does not, the
	// apply reads no cagg.
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
	if !strings.Contains(explain(inline), "cagg_watermark") {
		t.Fatal("the original UPDATE no longer shows an unconstified cagg_watermark() — re-check the premise")
	}
	st := caggsplit.Statements(split)
	if len(st) != 3 {
		t.Fatalf("want 3 statements, got %d", len(st))
	}
	if _, err := tx.Exec(ctx, st[0]); err != nil { // the split above left its snapshot table
		t.Fatal(err)
	}
	if p := explain(st[1]); strings.Contains(p, "cagg_watermark") {
		t.Errorf("the split read plans with an unconstified watermark:\n%s", p)
	}
	if strings.Contains(st[2], "agg_equipment_values_1hour") {
		t.Errorf("the apply reads the cagg:\n%s", st[2])
	}
}

// sameRows compares jsonb rows: every value exactly, except non-integral numbers,
// which may differ in their last bits (relative 1e-12). speed = avg(float8) is
// order-dependent, and the split's read is a different plan than the UPDATE's
// (the same rule as the rollup golden tests' gcsSame).
func sameRows(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] == b[i] {
			continue
		}
		var ma, mb map[string]any
		da, db := json.NewDecoder(strings.NewReader(a[i])), json.NewDecoder(strings.NewReader(b[i]))
		da.UseNumber()
		db.UseNumber()
		if da.Decode(&ma) != nil || db.Decode(&mb) != nil || len(ma) != len(mb) {
			return false
		}
		for k, va := range ma {
			na, aNum := va.(json.Number)
			nb, bNum := mb[k].(json.Number)
			if !aNum || !bNum {
				if !reflect.DeepEqual(va, mb[k]) {
					return false
				}
				continue
			}
			fa, e1 := na.Float64()
			fb, e2 := nb.Float64()
			if na != nb && (e1 != nil || e2 != nil || fa == math.Trunc(fa) && fb == math.Trunc(fb) ||
				math.Abs(fa-fb) > 1e-12*math.Max(math.Abs(fa), math.Abs(fb))) {
				return false
			}
		}
	}
	return true
}
