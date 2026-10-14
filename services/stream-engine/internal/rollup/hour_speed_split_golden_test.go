//go:build golden

// Golden fixture for the hour speed pass's read/apply split (ADR-0063 Phase A2,
// 2026-10-14), on a REAL TimescaleDB with a REAL real-time 1-minute cagg:
//
//   - TestGoldenHourSpeedCaggReadIsPlannedAsSelect: every statement of
//     hourSpeedSQL that reads equipment_categorical_1min must plan with a
//     constant watermark. The old single UPDATE did not (staging: raw tail priced
//     at 458 M rows, 6–9 s per tick against 107 ms for the same read as a
//     SELECT). The test also EXPLAINs the old statement and requires the trap to
//     show there, so it fails on the old code and cannot pass vacuously.
//
//   - TestGoldenHourSpeedSplitMatchesInline: same transaction (one now()), old
//     single statement vs CREATE TEMP TABLE … AS + UPDATE: identical
//     speed/ideal_speed on every hourly row, including an hour with no minutes
//     (zero fill), a LOCF ideal speed from equipment_values, the
//     equipments.production_speed fallback, and a row that is not eligible.
//
//     DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//     go test -tags golden -run GoldenHourSpeed -v ./internal/rollup/
package rollup

import (
	"context"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

const ghsp = "ghsp"

func ghspPool(t *testing.T) *pgxpool.Pool {
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
	pool, err := pgxpool.NewWithConfig(context.Background(), pc)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func ghspDest() flows.Dest {
	return flows.Dest{Name: "golden", EvSchema: ghsp, RefSchema: ghsp, SilverSchema: ghsp, GoldSchema: ghsp, GrainSchema: ghsp}
}

// hourSpeedInline rebuilds the pre-2026-10-14 single statement from hourSpeedSQL.
func hourSpeedInline(t *testing.T, split string) string {
	t.Helper()
	s := split
	for _, r := range [][2]string{
		{"\n\tDROP TABLE IF EXISTS pg_temp.hour_sp;\n\tCREATE TEMP TABLE hour_sp ON COMMIT DROP AS\n\tWITH sp AS (", "\n\tWITH sp AS ("},
		{"\n\tSELECT * FROM sp;\n\tUPDATE ", "\n\tUPDATE "},
		{"\n\t  FROM hour_sp sp\n", "\n\t  FROM sp\n"},
	} {
		n := strings.Replace(s, r[0], r[1], 1)
		if n == s {
			t.Fatalf("hourSpeedSQL changed shape: %q not found", r[0])
		}
		s = n
	}
	return s
}

func setupGHSP(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	s := ghsp
	for _, q := range []string{
		`CREATE EXTENSION IF NOT EXISTS timescaledb`,
		`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`,
		`CREATE SCHEMA ` + s,
		`CREATE TABLE ` + s + `.equipments (id_equipment int PRIMARY KEY, id_area int, id_enterprise int,
		    tp_equipment int, production_speed float8)`,
		// 1–3 lines (tp 3) and 4 a sector (tp 2); 5 is a machine (tp 1, not eligible)
		`INSERT INTO ` + s + `.equipments VALUES (1,10,7,3,120),(2,10,7,3,NULL),(3,10,7,3,90),(4,10,7,2,60),(5,10,7,1,30)`,
		`CREATE TABLE ` + s + `.equipment_values (ts_value timestamptz NOT NULL, id_equipment int,
		    speed float8, ideal_production_speed float8)`,
		`SELECT create_hypertable('` + s + `.equipment_values', 'ts_value', chunk_time_interval => interval '12 hours')`,
		// every equipment except 3 reports speed each minute for 3 days; ideal speed only
		// for equipment 2, and only before the last hour (so its last hour needs the LOCF)
		`INSERT INTO ` + s + `.equipment_values
		   SELECT m, e, 50 + e + extract(minute FROM m),
		          CASE WHEN e = 2 AND m < now() - interval '70 minutes' THEN 200 END
		     FROM generate_series(1, 5) e,
		          generate_series(date_trunc('minute', now()) - interval '3 days', date_trunc('minute', now()) - interval '1 minute', interval '1 minute') m
		    WHERE e <> 3`,
		`CREATE MATERIALIZED VIEW ` + s + `.equipment_categorical_1min
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 minute', ts_value) AS ts_value, id_equipment,
		        sum(speed) AS sum_speed, count(speed) AS cnt_speed,
		        max(ideal_production_speed) AS ideal_production_speed
		   FROM ` + s + `.equipment_values GROUP BY 1, 2 WITH NO DATA`,
		`CALL refresh_continuous_aggregate('` + s + `.equipment_categorical_1min', NULL, date_trunc('hour', now()) - interval '3 hours')`,
		`ANALYZE ` + s + `.equipment_values`,
		`CREATE TABLE ` + s + `.equipment_oee_hourly (id_equipment int, ts_value timestamptz,
		    speed float8, ideal_speed float8, recalc_needed boolean, target_customized boolean,
		    PRIMARY KEY (id_equipment, ts_value))`,
		// the current and previous hour for every equipment, flagged; equipment 4's previous hour is not
		`INSERT INTO ` + s + `.equipment_oee_hourly
		   SELECT e, h, -1, -1, NOT (e = 4 AND h < date_trunc('hour', now())), false
		     FROM generate_series(1, 5) e,
		          (VALUES (date_trunc('hour', now())), (date_trunc('hour', now()) - interval '1 hour')) v(h)`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("setup %q: %v", q, err)
		}
	}
}

func ghspElig(t *testing.T, ctx context.Context, tx pgx.Tx) {
	t.Helper()
	if _, err := tx.Exec(ctx, fmtRD(hourEligibleSQL, ghspDest()), []int{}, []int{}); err != nil {
		t.Fatalf("hour eligible: %v", err)
	}
}

func ghspDump(t *testing.T, ctx context.Context, tx pgx.Tx) []string {
	t.Helper()
	rows, err := tx.Query(ctx, `SELECT concat_ws('|', id_equipment, ts_value, speed, ideal_speed)
	                              FROM `+ghsp+`.equipment_oee_hourly ORDER BY id_equipment, ts_value`)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func ghspExplain(t *testing.T, ctx context.Context, pool *pgxpool.Pool, stmts ...string) string {
	t.Helper()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // plan only
	ghspElig(t, ctx, tx)
	var plans []string
	for _, st := range stmts {
		if strings.TrimSpace(st) == "" {
			continue
		}
		if !strings.Contains(st, "equipment_categorical_1min") {
			// a setup statement the next one depends on (DROP / the temp table)
			if _, err := tx.Exec(ctx, st); err != nil {
				t.Fatalf("exec %q: %v", st, err)
			}
			continue
		}
		rows, err := tx.Query(ctx, "EXPLAIN "+st)
		if err != nil {
			t.Fatalf("explain: %v", err)
		}
		lines, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		plans = append(plans, strings.Join(lines, "\n"))
		// create the temp table for real, so the UPDATE after it can be planned
		if strings.Contains(st, "CREATE TEMP TABLE") {
			if _, err := tx.Exec(ctx, st); err != nil {
				t.Fatalf("exec %q: %v", st, err)
			}
		}
	}
	return strings.Join(plans, "\n----\n")
}

func TestGoldenHourSpeedCaggReadIsPlannedAsSelect(t *testing.T) {
	pool := ghspPool(t)
	setupGHSP(t, pool)
	ctx := context.Background()
	split := fmtRD(hourSpeedSQL, ghspDest())

	if p := ghspExplain(t, ctx, pool, hourSpeedInline(t, split)); !strings.Contains(p, "cagg_watermark") {
		t.Fatal("the single-statement UPDATE no longer shows an unconstified cagg_watermark() — this TimescaleDB " +
			"constifies DML too; re-check the premise before trusting this test")
	}
	stmts := strings.Split(split, ";\n")
	readers := 0
	for _, st := range stmts {
		if strings.Contains(st, "equipment_categorical_1min") {
			readers++
		}
	}
	if readers == 0 {
		t.Fatal("no statement of hourSpeedSQL reads equipment_categorical_1min — the test proves nothing")
	}
	if p := ghspExplain(t, ctx, pool, stmts...); strings.Contains(p, "cagg_watermark") {
		t.Errorf("hourSpeedSQL reads the real-time cagg with an UNCONSTIFIED watermark (planned as DML):\n%s", p)
	}
	// the UPDATE itself must not read the cagg at all
	last := stmts[len(stmts)-1]
	if !strings.Contains(last, "UPDATE") || strings.Contains(last, "equipment_categorical_1min") {
		t.Errorf("the speed UPDATE must read only hour_sp, got:\n%s", last)
	}
}

func TestGoldenHourSpeedSplitMatchesInline(t *testing.T) {
	pool := ghspPool(t)
	setupGHSP(t, pool)
	ctx := context.Background()
	split := fmtRD(hourSpeedSQL, ghspDest())
	inline := hourSpeedInline(t, split)

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	ghspElig(t, ctx, tx)
	before := ghspDump(t, ctx, tx)
	if _, err := tx.Exec(ctx, "SAVEPOINT inline"); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, inline); err != nil {
		t.Fatalf("inline: %v", err)
	}
	want := ghspDump(t, ctx, tx)
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT inline"); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, split); err != nil {
		t.Fatalf("split: %v", err)
	}
	got := ghspDump(t, ctx, tx)
	// a second run in the same transaction (the history renderer repeats passes)
	if _, err := tx.Exec(ctx, split); err != nil {
		t.Fatalf("split, second run in one transaction: %v", err)
	}
	again := ghspDump(t, ctx, tx)

	if reflect.DeepEqual(before, want) {
		t.Fatal("the inline pass changed nothing — the comparison proves nothing")
	}
	changed := 0
	for i := range want {
		if want[i] != before[i] {
			changed++
		}
	}
	t.Logf("%d hourly rows, %d updated by the speed pass", len(want), changed)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("split differs from the inline statement:\n got  %v\n want %v", got, want)
	}
	if !reflect.DeepEqual(again, got) {
		t.Errorf("a second split run in one transaction changed the result:\n %v\n %v", again, got)
	}
}
