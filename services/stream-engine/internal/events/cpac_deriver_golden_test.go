//go:build golden

// Golden fixture for the CPAC deriver's read/apply split (2026-10-14). It runs
// against a REAL TimescaleDB with a REAL real-time continuous aggregate,
// because the bug lives in how TimescaleDB plans that cagg:
//
//   - TestGoldenCPACCaggReadIsPlannedAsSelect: every statement the deriver sends
//     that reads the categorical cagg must plan with a CONSTANT watermark.
//     TimescaleDB constifies the watermark only for a SELECT. Inside INSERT or
//     DELETE it stays a runtime cagg_watermark() call, and the planner prices the
//     raw tail at every equipment_values chunk. On staging those estimates turned
//     the upsert into a 62 × 157 k nested loop (1.3 s → 14 s) and kept the
//     correct pass at 12–21 s. The old code fails this test: its DELETE and INSERT
//     both read the cagg.
//
//   - TestGoldenCPACSnapshotMatchesInlineDerivation: same fixture, same
//     transaction (so the same now()), old inline statements vs the new
//     read + apply. The resulting table must be identical row for row, covering
//     inserts, ts_end/duration refreshes, stale-row deletes, a superseded row
//     under a human span, and the human row itself.
//
//     DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//     go test -tags golden -run GoldenCPAC -v ./internal/events/
package events

import (
	"context"
	"os"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const goldenCPACSchema = "cpac_golden"

// sqlRecorder is a pgx QueryTracer that records every statement + args.
type sqlRecorder struct {
	mu   sync.Mutex
	stmt []recordedStmt
}

type recordedStmt struct {
	sql  string
	args []any
}

func (r *sqlRecorder) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	r.mu.Lock()
	r.stmt = append(r.stmt, recordedStmt{sql: d.SQL, args: d.Args})
	r.mu.Unlock()
	return ctx
}

func (r *sqlRecorder) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

// goldenCPACPool connects like production does (simple protocol, see
// internal/db/pool.go) with an optional tracer.
func goldenCPACPool(t *testing.T, tracer pgx.QueryTracer) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	pc, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	if tracer != nil {
		pc.ConnConfig.Tracer = tracer
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), pc)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// goldenCPACEquipments sizes the fixture; CPAC_GOLDEN_EQUIPMENTS=62 matches
// staging CPACK for a local before/after timing.
func goldenCPACEquipments() int { return goldenCPACEnvInt("CPAC_GOLDEN_EQUIPMENTS", 8) }

// goldenCPACHistoryDays adds older, already-materialized raw history (one row per
// equipment per 10 min, 12 h chunks), the shape that makes the DML planner price
// the cagg's raw tail at every chunk. CPAC_GOLDEN_HISTORY_DAYS=60 for timing.
func goldenCPACHistoryDays() int { return goldenCPACEnvInt("CPAC_GOLDEN_HISTORY_DAYS", 0) }

func goldenCPACEnvInt(name string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n >= 0 {
		return n
	}
	return def
}

// setupGoldenCPAC builds: equipments, a raw equipment_values hypertable (12 h
// chunks), a real-time 1-minute cagg over it (materialized up to now()-3 h, so
// the watermark splits the read into materialized + raw tail), and the shadow
// target. Each equipment produces every minute for 27 h, except for a stop of
// 8 + n minutes every 70 + 9·n minutes.
func setupGoldenCPAC(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	s := goldenCPACSchema
	n := goldenCPACEquipments()
	for _, q := range []string{
		`CREATE EXTENSION IF NOT EXISTS timescaledb`,
		`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`,
		`CREATE SCHEMA ` + s,
		`CREATE TABLE ` + s + `.equipments (
			id_equipment int PRIMARY KEY, id_enterprise int, status_type int,
			tp_equipment int, stop_threshold_time int,
			lead_machine int, downtime_from_lead_machine boolean)`,
		`INSERT INTO ` + s + `.equipments
		   SELECT 1000 + e, 999, 0, 1, NULL, NULL, false FROM generate_series(1, ` + strconv.Itoa(n) + `) e`,
		`CREATE TABLE ` + s + `.equipment_values (
			ts_value timestamptz NOT NULL, id_equipment int,
			gross_production_incr float8, net_production_incr float8, scrap_incr float8)`,
		`SELECT create_hypertable('` + s + `.equipment_values', 'ts_value', chunk_time_interval => interval '12 hours')`,
		`INSERT INTO ` + s + `.equipment_values
		   SELECT m, 1000 + e, 1, 1, 0
		     FROM generate_series(1, ` + strconv.Itoa(n) + `) e,
		          generate_series(date_trunc('minute', now()) - interval '27 hours',
		                          date_trunc('minute', now()) - interval '1 minute', interval '1 minute') m
		    WHERE (extract(epoch FROM m)::bigint / 60) % (70 + 9 * e) >= 8 + e`,
		`INSERT INTO ` + s + `.equipment_values
		   SELECT m, 1000 + e, 1, 1, 0
		     FROM generate_series(1, ` + strconv.Itoa(n) + `) e,
		          generate_series(date_trunc('minute', now()) - interval '1 day' * ` + strconv.Itoa(goldenCPACHistoryDays()) + ` - interval '27 hours',
		                          date_trunc('minute', now()) - interval '27 hours' - interval '1 minute', interval '10 minutes') m`,
		`CREATE MATERIALIZED VIEW ` + s + `.equipment_categorical_1min
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 minute', ts_value) AS ts_value, id_equipment,
		        sum(gross_production_incr) AS gross_production_incr,
		        sum(net_production_incr) AS net_production_incr,
		        sum(scrap_incr) AS scrap_incr
		   FROM ` + s + `.equipment_values
		  GROUP BY 1, 2 WITH NO DATA`,
		`CALL refresh_continuous_aggregate('` + s + `.equipment_categorical_1min', NULL, date_trunc('hour', now()) - interval '3 hours')`,
		`ANALYZE ` + s + `.equipment_values`,
		`CREATE TABLE ` + s + `.equipment_events_cpac_shadow (
			id_equipment int, ts_event timestamptz, ts_end timestamptz,
			status int, id_enterprise int, duration int,
			forced_creation_system boolean,
			cd_category varchar, cd_subcategory varchar, cd_machine varchar,
			txt_downtime_notes varchar, planned_downtime boolean,
			change_over boolean, idle varchar,
			UNIQUE (id_equipment, ts_event))`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("setup %q: %v", q, err)
		}
	}
}

func goldenCPACDest(pool *pgxpool.Pool) Dest {
	return Dest{Name: "golden", Pool: pool, EvSchema: goldenCPACSchema, RefSchema: goldenCPACSchema, SilverSchema: goldenCPACSchema}
}

var goldenCPACCfg = CPACConfig{Enterprises: []int{999}, ThresholdDefSec: 300, TargetTable: DefaultCPACTargetTable}

// runInlineCPAC is the pre-2026-10-14 RunOnceCPAC body: the correct and upsert
// statements each recompute the derivation inline (cagg read inside the DML).
func runInlineCPAC(ctx context.Context, q interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}, d Dest, cfg CPACConfig) error {
	if _, err := q.Exec(ctx, fmtCPACFull(cpacCorrectSQL, d.EvSchema, d.RefSchema, cfg.TargetTable, "ev", d.SilverSchema, cfg.LeadActivity, cfg.LinkHealth), cfg.Enterprises, cfg.ThresholdDefSec); err != nil {
		return err
	}
	_, err := q.Exec(ctx, fmtCPACFull(cpacUpsertSQL, d.EvSchema, d.RefSchema, cfg.TargetTable, "ev", d.SilverSchema, cfg.LeadActivity, cfg.LinkHealth), cfg.Enterprises, cfg.ThresholdDefSec)
	return err
}

func goldenCPACDump(t *testing.T, ctx context.Context, tx pgx.Tx) []string {
	t.Helper()
	rows, err := tx.Query(ctx, `SELECT concat_ws('|', id_equipment, ts_event, ts_end, status, id_enterprise, duration,
	                                              forced_creation_system, cd_category, planned_downtime)
	                              FROM `+goldenCPACSchema+`.equipment_events_cpac_shadow ORDER BY id_equipment, ts_event`)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestGoldenCPACCaggReadIsPlannedAsSelect(t *testing.T) {
	rec := &sqlRecorder{}
	pool := goldenCPACPool(t, rec)
	setupGoldenCPAC(t, pool)
	ctx := context.Background()
	d := goldenCPACDest(pool)

	rec.mu.Lock()
	rec.stmt = nil
	rec.mu.Unlock()
	start := time.Now()
	if _, _, err := RunOnceCPAC(ctx, d, goldenCPACCfg); err != nil {
		t.Fatal(err)
	}
	t.Logf("RunOnceCPAC (%d equipments): %s", goldenCPACEquipments(), time.Since(start))

	plain := goldenCPACPool(t, nil)
	readers := 0
	for _, st := range rec.stmt {
		if !strings.Contains(st.sql, "equipment_categorical_1min") {
			continue
		}
		readers++
		tx, err := plain.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		rows, err := tx.Query(ctx, "EXPLAIN "+st.sql, st.args...)
		if err != nil {
			t.Fatalf("explain: %v", err)
		}
		lines, err := pgx.CollectRows(rows, pgx.RowTo[string])
		_ = tx.Rollback(ctx)
		if err != nil {
			t.Fatal(err)
		}
		plan := strings.Join(lines, "\n")
		if strings.Contains(plan, "cagg_watermark") {
			head := strings.TrimSpace(st.sql)
			if i := strings.LastIndex(head, "\nINSERT"); i >= 0 {
				head = head[i:]
			} else if i := strings.LastIndex(head, "\nDELETE"); i >= 0 {
				head = head[i:]
			}
			if len(head) > 60 {
				head = head[:60]
			}
			t.Errorf("a statement reads the real-time cagg with an UNCONSTIFIED watermark (planned as DML, "+
				"so the raw tail is priced at every chunk): %q…", strings.TrimSpace(head))
		}
	}
	if readers == 0 {
		t.Fatal("no recorded statement read equipment_categorical_1min — the test proves nothing")
	}
}

func TestGoldenCPACSnapshotMatchesInlineDerivation(t *testing.T) {
	pool := goldenCPACPool(t, nil)
	setupGoldenCPAC(t, pool)
	ctx := context.Background()
	d := goldenCPACDest(pool)
	s := goldenCPACSchema

	// A populated table to correct: one committed inline pass, then edits.
	if err := runInlineCPAC(ctx, pool, d, goldenCPACCfg); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		// stale derived row (no longer supported) → the correct pass deletes it
		`INSERT INTO ` + s + `.equipment_events_cpac_shadow (id_equipment, ts_event, status, id_enterprise, duration, forced_creation_system)
		 VALUES (1001, date_trunc('minute', now()) - interval '5 hours' + interval '17 seconds', 10, 999, 1, false)`,
		// wrong ts_end/duration on a real transition → the upsert refreshes it
		`UPDATE ` + s + `.equipment_events_cpac_shadow SET ts_end = ts_event + interval '1 second', duration = 1
		  WHERE (id_equipment, ts_event) IN (SELECT id_equipment, ts_event FROM ` + s + `.equipment_events_cpac_shadow
		                                      WHERE id_equipment = 1002 AND ts_end IS NOT NULL ORDER BY ts_event DESC LIMIT 3)`,
		// a human justification spanning 4 h on equipment 1003 → nothing re-minted
		// inside it, and the derived rows under it are swept as superseded
		`INSERT INTO ` + s + `.equipment_events_cpac_shadow (id_equipment, ts_event, ts_end, status, id_enterprise, duration, forced_creation_system, cd_category)
		 VALUES (1003, date_trunc('minute', now()) - interval '10 hours' + interval '30 seconds',
		               date_trunc('minute', now()) - interval '6 hours', 10, 999, 14370, false, 'JUSTIFIED')`,
		// a human-touched derived row outside any span → kept and never updated
		`UPDATE ` + s + `.equipment_events_cpac_shadow SET planned_downtime = true, duration = 7
		  WHERE (id_equipment, ts_event) = (SELECT id_equipment, ts_event FROM ` + s + `.equipment_events_cpac_shadow
		                                     WHERE id_equipment = 1004 AND status = 10 ORDER BY ts_event DESC LIMIT 1)`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("edit %q: %v", q, err)
		}
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	before := goldenCPACDump(t, ctx, tx)
	if _, err := tx.Exec(ctx, "SAVEPOINT inline"); err != nil {
		t.Fatal(err)
	}
	t0 := time.Now()
	if err := runInlineCPAC(ctx, tx, d, goldenCPACCfg); err != nil {
		t.Fatal(err)
	}
	tInline := time.Since(t0)
	want := goldenCPACDump(t, ctx, tx)
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT inline"); err != nil {
		t.Fatal(err)
	}
	t0 = time.Now()
	del, ups, err := runCPACTx(ctx, tx, d, goldenCPACCfg, DefaultCPACTargetTable, 300)
	if err != nil {
		t.Fatal(err)
	}
	tSnap := time.Since(t0)
	got := goldenCPACDump(t, ctx, tx)
	t.Logf("%d equipments: inline %s, snapshot %s (deleted %d, upserted %d); rows %d → %d",
		goldenCPACEquipments(), tInline, tSnap, del, ups, len(before), len(got))

	if del == 0 || ups == 0 {
		t.Fatalf("fixture must exercise both passes (deleted %d, upserted %d)", del, ups)
	}
	if reflect.DeepEqual(before, want) {
		t.Fatal("fixture edits changed nothing — the comparison proves nothing")
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("snapshot derivation differs from the inline one: %d vs %d rows", len(got), len(want))
		wantSet := map[string]bool{}
		for _, r := range want {
			wantSet[r] = true
		}
		gotSet := map[string]bool{}
		for _, r := range got {
			gotSet[r] = true
			if !wantSet[r] {
				t.Errorf("  only in snapshot: %s", r)
			}
		}
		for _, r := range want {
			if !gotSet[r] {
				t.Errorf("  only in inline:   %s", r)
			}
		}
	}
	for _, r := range got {
		if strings.HasPrefix(r, "1003|") && strings.Contains(r, "JUSTIFIED") {
			return
		}
	}
	t.Error("the human-justified row must survive")
}
