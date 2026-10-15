//go:build golden

// Golden fixture for every rollup read/apply split (cagg_split.go, ADR-0063 A2),
// on a REAL TimescaleDB with REAL real-time caggs (equipment_categorical_1min and
// _1hour over an equipment_values hypertable, part materialized, part raw tail):
//
//   - TestGoldenCaggSplitMatchesInline: in ONE transaction (one now()), each pass
//     runs as the original single statement and, after ROLLBACK TO SAVEPOINT, as
//     the split; the whole grain table must be identical — every column exactly,
//     except float8 aggregates, which may differ in their last ulps because the
//     split's read is a different plan and float sum/avg depend on row order
//     (gcsSame). Passes run in engine order on the split result,
//     so later passes see realistic input. The fixture covers a single-lead line,
//     a split-instrumentation line (gross/net/scrap machines), a counter-role line
//     with fill_missing_meter=false, a line with no lead, a sector on the counters-
//     only fallback, planned and unplanned events, silent minutes and an empty hour.
//     Each split also runs a second time in the same transaction (the history
//     renderer repeats passes) and must not change the result.
//
//   - TestGoldenCaggSplitReadsPlanAsSelect: every split read plans with a CONSTANT
//     watermark, every split apply reads no cagg, and every original statement
//     still shows the unconstified cagg_watermark() — so the test fails if
//     TimescaleDB ever changes the premise, instead of passing vacuously.
//
//     DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//     go test -tags golden -run GoldenCaggSplit -v ./internal/rollup/
package rollup

import (
	"context"
	"encoding/json"
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

const gcs = "gcs"

func gcsPool(t *testing.T) *pgxpool.Pool {
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

func gcsDest() flows.Dest {
	return flows.Dest{Name: "gcs", EvSchema: gcs, RefSchema: gcs, SilverSchema: gcs, GoldSchema: gcs, GrainSchema: gcs, ConfigSchema: gcs}
}

// Equipments: machines 101-107 (enterprise 3), lines 201-204, sector 205.
//
//	201 single-lead line (lead 101)
//	202 split-instrumentation line: lead 102, gross 103, net 104, scrap 105
//	203 counter roles (gross=processed, net=consumed) on lead 106, totalizer meters (fill_missing_meter=false)
//	204 line without a lead (ordinary state-event path; also on the count floor)
//	205 sector on the counters-only fallback (no events at all)
func setupGCS(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	s := gcs
	for _, q := range []string{
		`CREATE EXTENSION IF NOT EXISTS timescaledb`,
		`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`,
		`CREATE SCHEMA ` + s,
		`CREATE TABLE ` + s + `.equipments (id_equipment int PRIMARY KEY, id_site int, id_area int, id_enterprise int,
		    tp_equipment int, production_speed float8, lead_machine int, gross_machine int, net_machine int,
		    scrap_machine int, gross_counter text, net_counter text, fill_missing_meter boolean)`,
		`INSERT INTO ` + s + `.equipments VALUES
		    (101,1,10,3,1,60,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		    (102,1,10,3,1,50,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		    (103,1,10,3,1,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		    (104,1,10,3,1,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		    (105,1,10,3,1,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		    (106,1,10,3,1,40,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		    (201,1,10,3,3,NULL,101,NULL,NULL,NULL,NULL,NULL,NULL),
		    (202,1,10,3,3,NULL,102,103,104,105,NULL,NULL,NULL),
		    (203,1,10,3,3,NULL,106,NULL,NULL,NULL,'processed','consumed',false),
		    (204,1,10,3,3,90,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		    (205,1,10,3,2,30,NULL,NULL,NULL,NULL,NULL,NULL,NULL)`,
		`CREATE TABLE ` + s + `.shifts (id_shift int PRIMARY KEY, cd_shift text)`,
		`INSERT INTO ` + s + `.shifts VALUES (1,'T1')`,
		`CREATE TABLE ` + s + `.equipment_values (ts_value timestamptz NOT NULL, id_equipment int,
		    gross_production_incr float8, net_production_incr float8, scrap_incr float8,
		    speed float8, ideal_production_speed float8, state int, id_shift int, ts_value_production timestamptz)`,
		`SELECT create_hypertable('` + s + `.equipment_values', 'ts_value', chunk_time_interval => interval '6 hours')`,
		// 3 days of minutes. Every machine counts most minutes; each has its own
		// silent stretches (minute pattern) so sessions, gaps and silent hours occur.
		// 104 (202's net machine) and 106 differ in counters so the reconcile
		// branches split. 204/205 count on their own rows. 201's lead 101 is dark
		// for the most recent 40 minutes (lead-silent fallback has no gross/net
		// machine, so the hour reads as idle). 30701 arrives for 204 only, and only
		// before the last 70 minutes (LOCF + production_speed fallbacks both used).
		`INSERT INTO ` + s + `.equipment_values
		   SELECT m, e,
		          CASE WHEN (extract(minute FROM m)::int + e) % 11 IN (0, 1) THEN 0 ELSE 3 + (e % 4) END,
		          CASE WHEN e = 103 THEN 0
		               WHEN (extract(minute FROM m)::int + e) % 11 IN (0, 1) THEN 0 ELSE 2 + (e % 3) END,
		          CASE WHEN (extract(minute FROM m)::int + e) % 7 = 0 THEN 1 ELSE 0 END,
		          40 + e % 9 + extract(minute FROM m)::int % 5,
		          CASE WHEN e = 204 AND m < now() - interval '70 minutes' THEN 95 END,
		          CASE WHEN (extract(minute FROM m)::int + e) % 11 IN (0, 1) THEN 5 ELSE 6 END,
		          1, date_trunc('day', m)
		     FROM generate_series(101, 106) e0
		     CROSS JOIN LATERAL (SELECT e0 AS e UNION ALL SELECT 204 WHERE e0 = 101 UNION ALL SELECT 205 WHERE e0 = 102) x,
		          generate_series(date_trunc('minute', now()) - interval '3 days', date_trunc('minute', now()) - interval '1 minute', interval '1 minute') m
		    WHERE NOT (e = 101 AND m >= now() - interval '40 minutes')
		      AND NOT (e = 105 AND extract(hour FROM m)::int % 5 = 0)`,
		`CREATE MATERIALIZED VIEW ` + s + `.equipment_categorical_1min
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 minute', ts_value) AS ts_value, id_equipment,
		        sum(gross_production_incr) AS gross_production_incr, sum(net_production_incr) AS net_production_incr,
		        sum(scrap_incr) AS scrap_incr, sum(speed) AS sum_speed, count(speed) AS cnt_speed,
		        max(ideal_production_speed) AS ideal_production_speed
		   FROM ` + s + `.equipment_values GROUP BY 1, 2 WITH NO DATA`,
		`CREATE MATERIALIZED VIEW ` + s + `.equipment_categorical_1hour
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 hour', ts_value) AS ts_value, id_equipment, id_shift, ts_value_production, state,
		        sum(gross_production_incr) AS gross_production_incr, sum(net_production_incr) AS net_production_incr,
		        sum(scrap_incr) AS scrap_incr, sum(speed) AS sum_speed, count(speed) AS cnt_speed,
		        max(ideal_production_speed) AS ideal_production_speed
		   FROM ` + s + `.equipment_values GROUP BY 1, 2, 3, 4, 5 WITH NO DATA`,
		// materialize all but the last 3 hours: the live hours come from the raw tail
		`CALL refresh_continuous_aggregate('` + s + `.equipment_categorical_1min', NULL, date_trunc('hour', now()) - interval '3 hours')`,
		`CALL refresh_continuous_aggregate('` + s + `.equipment_categorical_1hour', NULL, date_trunc('hour', now()) - interval '3 hours')`,
		`ANALYZE ` + s + `.equipment_values`,
		`CREATE TABLE ` + s + `.equipment_events (id_equipment int, ts_event timestamptz, ts_end timestamptz,
		    status int, planned_downtime boolean, change_over boolean, PRIMARY KEY (id_equipment, ts_event))`,
		// open-ended state markers for the lines (205 has none: counters-only).
		// 201/202/203: running, a planned stop, running again; 204: running with an
		// unplanned stop and a changeover; one event before every lookback (in effect).
		`INSERT INTO ` + s + `.equipment_events VALUES
		    (201, now() - interval '40 days', NULL, 6, false, false),
		    (201, now() - interval '100 minutes', NULL, 5, true, false),
		    (201, now() - interval '80 minutes', NULL, 6, false, false),
		    (201, now() - interval '20 hours', NULL, 10, false, false),
		    (201, now() - interval '19 hours', NULL, 6, false, false),
		    (202, now() - interval '2 days', NULL, 6, false, false),
		    (202, now() - interval '50 minutes', NULL, 5, true, false),
		    (202, now() - interval '35 minutes', NULL, 6, false, false),
		    (203, now() - interval '30 hours', NULL, 6, false, false),
		    (203, now() - interval '25 minutes', now() - interval '10 minutes', 11, false, false),
		    (204, now() - interval '3 days', NULL, 6, false, false),
		    (204, now() - interval '70 minutes', NULL, 10, false, false),
		    (204, now() - interval '62 minutes', NULL, 6, false, true),
		    (204, now() - interval '55 minutes', NULL, 6, false, false),
		    (204, now() - interval '9 hours', NULL, 5, false, false),
		    (204, now() - interval '8 hours', NULL, 6, false, false),
		    -- inside an eligible hour bucket whatever the minute (the hour window is
		    -- 65 min): 204 stops unplanned while its meter keeps counting (the count
		    -- floor raises it), 201 takes a planned stop (line-lead planned time).
		    (204, now() - interval '20 minutes', NULL, 10, false, false),
		    (204, now() - interval '12 minutes', NULL, 6, false, false),
		    (201, now() - interval '18 minutes', NULL, 5, true, false),
		    (201, now() - interval '9 minutes', NULL, 6, false, false)`,
		`CREATE TABLE ` + s + `.equipment_oee_hourly (id_equipment int, ts_value timestamptz, ts_value_production timestamptz,
		    target_customized boolean, recalc_needed boolean,
		    gross float8, net float8, scrap float8, speed float8, ideal_speed float8,
		    available_time float8, running_time float8, stopped_time float8, planned_downtime float8,
		    ideal_production float8, downtime float8, changeover_time float8,
		    oee float8, oee_a float8, oee_p float8, oee_q float8, proportional_target float8,
		    PRIMARY KEY (id_equipment, ts_value))`,
		// current + previous hour for every line/sector, flagged
		`INSERT INTO ` + s + `.equipment_oee_hourly (id_equipment, ts_value, ts_value_production, target_customized, recalc_needed)
		   SELECT e, h, date_trunc('day', h), false, true
		     FROM generate_series(201, 205) e,
		          (VALUES (date_trunc('hour', now())), (date_trunc('hour', now()) - interval '1 hour')) v(h)`,
		`CREATE TABLE ` + s + `.equipment_oee_shift (id_equipment int, ts_value timestamptz, ts_end timestamptz,
		    ts_value_production timestamptz, id_shift int, cd_shift text, target_customized boolean, recalc_needed boolean,
		    computed_at timestamptz,
		    gross float8, net float8, scrap float8, speed float8, ideal_speed float8,
		    available_time float8, running_time float8, stopped_time float8, planned_downtime float8,
		    ideal_production float8, downtime float8, changeover_time float8,
		    oee float8, oee_a float8, oee_p float8, oee_q float8, proportional_target float8,
		    PRIMARY KEY (id_equipment, ts_value))`,
		// 8-hour shifts for the last 2 days, the live one included, flagged
		`INSERT INTO ` + s + `.equipment_oee_shift (id_equipment, ts_value, ts_end, ts_value_production, id_shift, target_customized, recalc_needed, running_time, available_time)
		   SELECT e, b, b + interval '8 hours', date_trunc('day', b), 1, false, true, 0, 0
		     FROM generate_series(201, 205) e,
		          generate_series(date_trunc('day', now()) - interval '2 days', now(), interval '8 hours') b`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("setup %q: %v", q[:min(len(q), 80)], err)
		}
	}
}

var gcsLineLeadPred = LineLeadScope{Enterprises: []int{3}}.Predicate(pgIntArrayLiteral([]int{3}))

// gcsPass is one split pass: the original single statement and the split form,
// rendered for the fixture schema.
type gcsPass struct {
	name          string
	inline, split string
}

func gcsHourPasses() []gcsPass {
	d := gcsDest()
	return []gcsPass{
		{"hour values", fmtRD(hourValuesSQL, d), fmtRD(hourValuesSplitSQL, d)},
		{"hour events", fmtRD(hourEventsSQL, d, plannedDowntimeExpr(false)), fmtRD(hourEventsSplitSQL, d, plannedDowntimeExpr(false))},
		{"hour counters-avail", fmtRD(hourCountsAvailSQL, d, pgIntArrayLiteral([]int{205}), 300),
			fmtRD(hourCountsAvailSplitSQL, d, pgIntArrayLiteral([]int{205}), 300)},
		{"hour line-lead", fmtRD(withPlannedPred(hourLineLeadSQL, false), d, gcsLineLeadPred, 300),
			fmtRD(withPlannedPred(hourLineLeadSplitSQL, false), d, gcsLineLeadPred, 300)},
		{"hour avail-floor", fmtRD(hourAvailFloorSQL, d, pgIntArrayLiteral([]int{204, 205}), 300),
			fmtRD(hourAvailFloorSplitSQL, d, pgIntArrayLiteral([]int{204, 205}), 300)},
	}
}

func gcsShiftPasses() []gcsPass {
	d := gcsDest()
	return []gcsPass{
		{"shift values", fmtRD(shiftValuesSQL, d), fmtRD(shiftValuesSplitSQL, d)},
		{"shift counters-avail", fmtRD(shiftCountsAvailSQL, d, pgIntArrayLiteral([]int{205}), 300),
			fmtRD(shiftCountsAvailSplitSQL, d, pgIntArrayLiteral([]int{205}), 300)},
		{"shift line-lead", fmtRD(withPlannedPred(shiftLineLeadSQL, false), d, gcsLineLeadPred, 300),
			fmtRD(withPlannedPred(shiftLineLeadSplitSQL, false), d, gcsLineLeadPred, 300)},
		{"shift avail-floor", fmtRD(shiftAvailFloorSQL, d, pgIntArrayLiteral([]int{204, 205}), 300),
			fmtRD(shiftAvailFloorSplitSQL, d, pgIntArrayLiteral([]int{204, 205}), 300)},
	}
}

func gcsExec(t *testing.T, ctx context.Context, tx pgx.Tx, what, sql string, args ...any) {
	t.Helper()
	if _, err := tx.Exec(ctx, sql, args...); err != nil {
		t.Fatalf("%s: %v", what, err)
	}
}

func gcsDump(t *testing.T, ctx context.Context, tx pgx.Tx, table string) []string {
	t.Helper()
	rows, err := tx.Query(ctx, `SELECT to_jsonb(t)::text FROM `+gcs+`.`+table+` t ORDER BY id_equipment, ts_value`)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// gcsSame compares two dumped rows: every value exactly, except that two
// non-integral numbers may differ in their last bits (relative 1e-12). Why: float8
// sum()/avg() are not associative, so their last ulp depends on the order the plan
// feeds rows in — and the split's read gets a DIFFERENT (better) plan than the
// single DML. The single statement has the same exposure whenever its own plan
// changes (stats, data volume), so this is the strongest equality a re-planned
// statement can promise. ulps counts such values so the log shows them.
func gcsSame(a, b string, ulps *int) bool {
	if a == b {
		return true
	}
	var ma, mb map[string]any
	da, db := json.NewDecoder(strings.NewReader(a)), json.NewDecoder(strings.NewReader(b))
	da.UseNumber()
	db.UseNumber()
	if da.Decode(&ma) != nil || db.Decode(&mb) != nil || len(ma) != len(mb) {
		return false
	}
	for k, va := range ma {
		vb, ok := mb[k]
		if !ok {
			return false
		}
		na, aNum := va.(json.Number)
		nb, bNum := vb.(json.Number)
		if !aNum || !bNum {
			if !reflect.DeepEqual(va, vb) {
				return false
			}
			continue
		}
		if na == nb {
			continue
		}
		fa, e1 := na.Float64()
		fb, e2 := nb.Float64()
		if e1 != nil || e2 != nil || fa == math.Trunc(fa) && fb == math.Trunc(fb) ||
			math.Abs(fa-fb) > 1e-12*math.Max(math.Abs(fa), math.Abs(fb)) {
			return false
		}
		*ulps++
	}
	return true
}

// gcsCompare runs one pass inline and split in tx and requires identical tables.
// It leaves the SPLIT result in place for the next pass.
func gcsCompare(t *testing.T, ctx context.Context, tx pgx.Tx, table string, p gcsPass) {
	t.Helper()
	before := gcsDump(t, ctx, tx, table)
	gcsExec(t, ctx, tx, "savepoint", "SAVEPOINT gcs_pass")
	gcsExec(t, ctx, tx, p.name+" (inline)", p.inline)
	want := gcsDump(t, ctx, tx, table)
	gcsExec(t, ctx, tx, "rollback to savepoint", "ROLLBACK TO SAVEPOINT gcs_pass")
	gcsExec(t, ctx, tx, p.name+" (split)", p.split)
	got := gcsDump(t, ctx, tx, table)
	gcsExec(t, ctx, tx, p.name+" (split, again)", p.split)
	again := gcsDump(t, ctx, tx, table)

	changed := 0
	for i := range want {
		if want[i] != before[i] {
			changed++
		}
	}
	if changed == 0 {
		t.Errorf("%s: the inline statement changed no row — the comparison proves nothing", p.name)
	}
	if len(got) != len(want) {
		t.Fatalf("%s: %d rows vs %d", p.name, len(got), len(want))
	}
	ulps := 0
	for i := range want {
		if !gcsSame(got[i], want[i], &ulps) {
			t.Errorf("%s: split differs from inline:\n got  %s\n want %s", p.name, got[i], want[i])
		}
	}
	t.Logf("%s: %d of %d %s rows written; identical, %d float aggregate(s) differing only in the last ulps (summation order)",
		p.name, changed, len(want), table, ulps)
	if !reflect.DeepEqual(again, got) {
		t.Errorf("%s: a second split run in one transaction changed the result", p.name)
	}
}

func TestGoldenCaggSplitMatchesInline(t *testing.T) {
	pool := gcsPool(t)
	setupGCS(t, pool)
	ctx := context.Background()
	d := gcsDest()

	t.Run("hour", func(t *testing.T) {
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx) //nolint:errcheck
		gcsExec(t, ctx, tx, "hour eligible", fmtRD(hourEligibleSQL, d), []int{}, []int{})
		for _, p := range gcsHourPasses() {
			gcsCompare(t, ctx, tx, "equipment_oee_hourly", p)
			if p.name == "hour values" {
				// the speed pass (#1775, already split) feeds ideal_speed to events/line-lead
				gcsExec(t, ctx, tx, "hour speed", fmtRD(hourSpeedSQL, d))
			}
		}
	})
	t.Run("shift", func(t *testing.T) {
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx) //nolint:errcheck
		gcsExec(t, ctx, tx, "shift eligible", fmtRD(shiftEligibleSQL, d, 1000), []int{}, []int{}, []int{})
		for _, p := range gcsShiftPasses() {
			gcsCompare(t, ctx, tx, "equipment_oee_shift", p)
			if p.name == "shift values" {
				// events-bank (a CREATE TABLE AS — already a SELECT) + its update: the
				// counters-avail pass reads shift_ev, line-lead overrides the update.
				gcsExec(t, ctx, tx, "shift events-bank", fmtRD(shiftEventsSQL, d, plannedDowntimeExpr(false)))
				gcsExec(t, ctx, tx, "shift events-update", fmtRD(shiftEventsUpdateSQL, d))
			}
		}
	})
}

func gcsExplain(t *testing.T, ctx context.Context, tx pgx.Tx, sql string) string {
	t.Helper()
	rows, err := tx.Query(ctx, "EXPLAIN "+sql)
	if err != nil {
		t.Fatalf("explain: %v\n%s", err, sql)
	}
	lines, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return strings.Join(lines, "\n")
}

func TestGoldenCaggSplitReadsPlanAsSelect(t *testing.T) {
	pool := gcsPool(t)
	setupGCS(t, pool)
	ctx := context.Background()
	d := gcsDest()
	readsCagg := func(s string) bool {
		return strings.Contains(s, "equipment_categorical_1min") || strings.Contains(s, "equipment_categorical_1hour")
	}
	for _, grain := range []struct {
		elig   string
		args   []any
		passes []gcsPass
		prep   map[string]string // statements to run (for real) before a pass is planned
	}{
		{fmtRD(hourEligibleSQL, d), []any{[]int{}, []int{}}, gcsHourPasses(), nil},
		{fmtRD(shiftEligibleSQL, d, 1000), []any{[]int{}, []int{}, []int{}}, gcsShiftPasses(),
			map[string]string{"shift counters-avail": fmtRD(shiftEventsSQL, d, plannedDowntimeExpr(false))}},
	} {
		for _, p := range grain.passes {
			t.Run(p.name, func(t *testing.T) {
				tx, err := pool.Begin(ctx)
				if err != nil {
					t.Fatal(err)
				}
				defer tx.Rollback(ctx) //nolint:errcheck
				gcsExec(t, ctx, tx, "eligible", grain.elig, grain.args...)
				if prep, ok := grain.prep[p.name]; ok {
					gcsExec(t, ctx, tx, "prep", prep)
				}
				if plan := gcsExplain(t, ctx, tx, p.inline); !strings.Contains(plan, "cagg_watermark") {
					t.Fatalf("the ORIGINAL %s no longer plans with an unconstified cagg_watermark() — this "+
						"TimescaleDB constifies DML too; re-check the premise before trusting this test", p.name)
				}
				st := caggsplit.Statements(p.split)
				if len(st) != 3 || !strings.Contains(st[1], "CREATE TEMP TABLE") {
					t.Fatalf("%s: want DROP / CREATE TEMP TABLE AS / apply, got %d statements", p.name, len(st))
				}
				if !readsCagg(st[1]) {
					t.Fatalf("%s: the read does not read the cagg — the test proves nothing", p.name)
				}
				if plan := gcsExplain(t, ctx, tx, st[1]); strings.Contains(plan, "cagg_watermark") {
					t.Errorf("%s: the read plans with an UNCONSTIFIED watermark:\n%s", p.name, plan)
				}
				if readsCagg(st[2]) {
					t.Errorf("%s: the apply reads a cagg:\n%s", p.name, st[2])
				}
				gcsExec(t, ctx, tx, "drop", st[0])
				gcsExec(t, ctx, tx, "read", st[1])
				if plan := gcsExplain(t, ctx, tx, st[2]); strings.Contains(plan, "cagg_watermark") {
					t.Errorf("%s: the apply plan touches a cagg:\n%s", p.name, plan)
				}
			})
		}
	}
}
