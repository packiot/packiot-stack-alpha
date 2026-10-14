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
	if _, _, _, err := RunOnceCPAC(ctx, d, goldenCPACCfg); err != nil {
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
	del, ups, _, err := runCPACTx(ctx, tx, d, goldenCPACCfg, DefaultCPACTargetTable, 300)
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

// applyCPACWith is runCPACTx with a caller-chosen upsert half, so a test can run
// the pre-guard DO UPDATE against the same snapshot.
func applyCPACWith(ctx context.Context, tx pgx.Tx, d Dest, cfg CPACConfig, upsertApply string) (del, ups, cls int64, err error) {
	var snap string
	if err = tx.QueryRow(ctx, fmtCPACFull(cpacReadSQL, d.EvSchema, d.RefSchema, cfg.TargetTable, "ev", d.SilverSchema, cfg.LeadActivity, cfg.LinkHealth),
		cfg.Enterprises, cfg.ThresholdDefSec).Scan(&snap); err != nil {
		return
	}
	for i, st := range []struct {
		apply string
		args  []any
		param string
	}{{cpacCorrectApply, []any{cfg.Enterprises, snap}, "$2"}, {upsertApply, []any{snap}, "$1"}, {cpacCloseApply, []any{snap}, "$1"}} {
		tag, e := tx.Exec(ctx, cpacApplySQL(st.apply, d.EvSchema, d.RefSchema, cfg.TargetTable, "ev", d.SilverSchema, st.param), st.args...)
		if e != nil {
			return 0, 0, 0, e
		}
		switch i {
		case 0:
			del = tag.RowsAffected()
		case 1:
			ups = tag.RowsAffected()
		default:
			cls = tag.RowsAffected()
		}
	}
	return
}

// unguardedUpsertApply is cpacUpsertApply before 2026-10-14 (no no-op guard).
func unguardedUpsertApply(t *testing.T) string {
	t.Helper()
	s := strings.Replace(cpacUpsertApply, cpacNoopGuard, "", 1)
	if s == cpacUpsertApply {
		t.Fatal("cpacNoopGuard not found in cpacUpsertApply")
	}
	return s
}

// goldenCPACXactWrites reads this transaction's own row-write counters for the
// target (pg_stat_xact_* sees them before commit).
func goldenCPACXactWrites(t *testing.T, ctx context.Context, tx pgx.Tx) (ins, upd, del int64) {
	t.Helper()
	if err := tx.QueryRow(ctx, `SELECT n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_xact_user_tables
	                             WHERE relid = '`+goldenCPACSchema+`.equipment_events_cpac_shadow'::regclass`).Scan(&ins, &upd, &del); err != nil {
		t.Fatal(err)
	}
	return
}

// TestGoldenCPACNoopGuardKeepsResults: with the no-op guard the table ends up
// row-for-row identical to the pre-guard DO UPDATE, on the same edited fixture
// (stale delete, wrong ts_end refresh, human span, human row) and the same
// now(); only the number of rewritten rows drops.
func TestGoldenCPACNoopGuardKeepsResults(t *testing.T) {
	pool := goldenCPACPool(t, nil)
	setupGoldenCPAC(t, pool)
	ctx := context.Background()
	d := goldenCPACDest(pool)
	s := goldenCPACSchema
	if _, _, _, err := RunOnceCPAC(ctx, d, goldenCPACCfg); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`INSERT INTO ` + s + `.equipment_events_cpac_shadow (id_equipment, ts_event, status, id_enterprise, duration, forced_creation_system)
		 VALUES (1001, date_trunc('minute', now()) - interval '5 hours' + interval '17 seconds', 10, 999, 1, false)`,
		`UPDATE ` + s + `.equipment_events_cpac_shadow SET ts_end = ts_event + interval '1 second', duration = 1
		  WHERE (id_equipment, ts_event) IN (SELECT id_equipment, ts_event FROM ` + s + `.equipment_events_cpac_shadow
		                                      WHERE id_equipment = 1002 AND ts_end IS NOT NULL ORDER BY ts_event DESC LIMIT 3)`,
		`UPDATE ` + s + `.equipment_events_cpac_shadow SET status = 6
		  WHERE (id_equipment, ts_event) = (SELECT id_equipment, ts_event FROM ` + s + `.equipment_events_cpac_shadow
		                                     WHERE id_equipment = 1005 AND status = 10 ORDER BY ts_event DESC LIMIT 1)`,
		`INSERT INTO ` + s + `.equipment_events_cpac_shadow (id_equipment, ts_event, ts_end, status, id_enterprise, duration, forced_creation_system, cd_category)
		 VALUES (1003, date_trunc('minute', now()) - interval '10 hours' + interval '30 seconds',
		               date_trunc('minute', now()) - interval '6 hours', 10, 999, 14370, false, 'JUSTIFIED')`,
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
	if _, err := tx.Exec(ctx, "SAVEPOINT old"); err != nil {
		t.Fatal(err)
	}
	_, upsOld, _, err := applyCPACWith(ctx, tx, d, goldenCPACCfg, unguardedUpsertApply(t))
	if err != nil {
		t.Fatal(err)
	}
	want := goldenCPACDump(t, ctx, tx)
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT old"); err != nil {
		t.Fatal(err)
	}
	_, upsNew, _, err := runCPACTx(ctx, tx, d, goldenCPACCfg, DefaultCPACTargetTable, 300)
	if err != nil {
		t.Fatal(err)
	}
	got := goldenCPACDump(t, ctx, tx)
	t.Logf("rows written by the upsert: unguarded %d, guarded %d (table %d rows)", upsOld, upsNew, len(got))
	if !reflect.DeepEqual(got, want) {
		t.Errorf("guarded upsert result differs from the unguarded one (%d vs %d rows)", len(got), len(want))
	}
	// the 3 + 1 corrupted rows, the open tail rows and re-minted rows must still be written
	if upsNew < 4 {
		t.Errorf("guarded upsert wrote %d rows; the fixture's 4 changed rows must still be rewritten", upsNew)
	}
	if upsNew >= upsOld {
		t.Errorf("guard saved nothing: guarded %d vs unguarded %d", upsNew, upsOld)
	}
}

// TestGoldenCPACUnchangedTickWritesNothing: a tick whose derivation matches the
// table writes 0 rows (pg_stat n_tup_upd/ins/del unchanged), and a changed row
// is still rewritten, exactly once. Both ticks run in ONE transaction, so now()
// and therefore the open tail's duration are identical.
func TestGoldenCPACUnchangedTickWritesNothing(t *testing.T) {
	pool := goldenCPACPool(t, nil)
	setupGoldenCPAC(t, pool)
	ctx := context.Background()
	d := goldenCPACDest(pool)
	s := goldenCPACSchema
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, ups, _, err := runCPACTx(ctx, tx, d, goldenCPACCfg, DefaultCPACTargetTable, 300); err != nil || ups == 0 {
		t.Fatalf("first tick: ups %d err %v", ups, err)
	}
	first := goldenCPACDump(t, ctx, tx)
	i0, u0, d0 := goldenCPACXactWrites(t, ctx, tx)

	del, ups, cls, err := runCPACTx(ctx, tx, d, goldenCPACCfg, DefaultCPACTargetTable, 300)
	if err != nil {
		t.Fatal(err)
	}
	i1, u1, d1 := goldenCPACXactWrites(t, ctx, tx)
	if del != 0 || ups != 0 || cls != 0 || i1 != i0 || u1 != u0 || d1 != d0 {
		t.Errorf("unchanged tick wrote rows: affected del=%d ups=%d cls=%d; n_tup ins %d→%d upd %d→%d del %d→%d",
			del, ups, cls, i0, i1, u0, u1, d0, d1)
	}
	if !reflect.DeepEqual(goldenCPACDump(t, ctx, tx), first) {
		t.Error("unchanged tick changed the table")
	}

	// contrast: the pre-guard upsert rewrites every derived row on the same tick
	if _, err := tx.Exec(ctx, "SAVEPOINT old"); err != nil {
		t.Fatal(err)
	}
	if _, upsOld, _, err := applyCPACWith(ctx, tx, d, goldenCPACCfg, unguardedUpsertApply(t)); err != nil || upsOld < int64(len(first))/2 {
		t.Errorf("unguarded control: ups %d of %d rows, err %v (expected it to rewrite the window)", upsOld, len(first), err)
	}
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT old"); err != nil {
		t.Fatal(err)
	}

	// one changed row is still rewritten, and only it
	if _, err := tx.Exec(ctx, `UPDATE `+s+`.equipment_events_cpac_shadow SET ts_end = ts_end + interval '1 second', duration = duration + 1
	   WHERE (id_equipment, ts_event) = (SELECT id_equipment, ts_event FROM `+s+`.equipment_events_cpac_shadow
	                                      WHERE id_equipment = 1002 AND ts_end IS NOT NULL ORDER BY ts_event DESC LIMIT 1)`); err != nil {
		t.Fatal(err)
	}
	_, u2, _ := goldenCPACXactWrites(t, ctx, tx)
	_, ups, _, err = runCPACTx(ctx, tx, d, goldenCPACCfg, DefaultCPACTargetTable, 300)
	if err != nil {
		t.Fatal(err)
	}
	_, u3, _ := goldenCPACXactWrites(t, ctx, tx)
	if ups != 1 || u3-u2 != 1 {
		t.Errorf("changed row: upsert affected %d rows, n_tup_upd +%d (want 1, 1)", ups, u3-u2)
	}
	if !reflect.DeepEqual(goldenCPACDump(t, ctx, tx), first) {
		t.Error("the changed row was not restored to the derived values")
	}
}

// TestGoldenCPACClosesRowLeftOpenBeforeWindow: a row that left the 25 h window
// while open (a stop longer than the window) ends where the next row begins once
// the machine changes state. Only the newest pre-window row per equipment is
// considered; a human-touched row and an already-closed row are never changed;
// a second tick closes nothing. Gross-only (CPACK shadow) and LeadActivity
// (the live instance's apply is the same SQL) both.
func TestGoldenCPACClosesRowLeftOpenBeforeWindow(t *testing.T) {
	for _, cfg := range []CPACConfig{goldenCPACCfg, {Enterprises: []int{999}, ThresholdDefSec: 300, TargetTable: DefaultCPACTargetTable, LeadActivity: true}} {
		t.Run("lead="+strconv.FormatBool(cfg.LeadActivity), func(t *testing.T) {
			pool := goldenCPACPool(t, nil)
			setupGoldenCPAC(t, pool)
			ctx := context.Background()
			d := goldenCPACDest(pool)
			s := goldenCPACSchema
			for _, q := range []string{
				// 1001: an older open row (backlog: not the newest pre-window row → left to the one-time repair)
				// and the newest pre-window row, an open stop → closed at 1001's first in-window row
				`INSERT INTO ` + s + `.equipment_events_cpac_shadow (id_equipment, ts_event, status, id_enterprise, duration, forced_creation_system)
				 VALUES (1001, date_trunc('minute', now()) - interval '40 hours', 6, 999, 60, false),
				        (1001, date_trunc('minute', now()) - interval '30 hours' + interval '1 second', 10, 999, 60, false)`,
				// 1002: open but human-justified → never changed
				`INSERT INTO ` + s + `.equipment_events_cpac_shadow (id_equipment, ts_event, status, id_enterprise, duration, forced_creation_system, cd_category)
				 VALUES (1002, date_trunc('minute', now()) - interval '30 hours' + interval '1 second', 10, 999, 60, false, 'JUSTIFIED')`,
				// 1004: already closed → never changed
				`INSERT INTO ` + s + `.equipment_events_cpac_shadow (id_equipment, ts_event, ts_end, status, id_enterprise, duration, forced_creation_system)
				 VALUES (1004, date_trunc('minute', now()) - interval '30 hours' + interval '1 second',
				               date_trunc('minute', now()) - interval '29 hours', 10, 999, 3599, false)`,
			} {
				if _, err := pool.Exec(ctx, q); err != nil {
					t.Fatalf("seed %q: %v", q, err)
				}
			}
			_, _, cls, err := RunOnceCPAC(ctx, d, cfg)
			if err != nil {
				t.Fatal(err)
			}
			if cls != 1 {
				t.Errorf("closed %d rows, want 1 (1001's newest pre-window stop)", cls)
			}
			var okEnd, okDur bool
			if err := pool.QueryRow(ctx, `SELECT ev.ts_end = (SELECT min(n.ts_event) FROM `+s+`.equipment_events_cpac_shadow n
			                                                  WHERE n.id_equipment = 1001 AND n.ts_event > ev.ts_event),
			                                     ev.duration = extract(epoch FROM ev.ts_end - ev.ts_event)::int
			                                FROM `+s+`.equipment_events_cpac_shadow ev
			                               WHERE ev.id_equipment = 1001 AND ev.ts_event = date_trunc('minute', now()) - interval '30 hours' + interval '1 second'`).Scan(&okEnd, &okDur); err != nil {
				t.Fatal(err)
			}
			if !okEnd || !okDur {
				t.Errorf("1001's stop must end at its successor (ts_end ok=%v, duration ok=%v)", okEnd, okDur)
			}
			var stillOpen40, human, closed1004 bool
			if err := pool.QueryRow(ctx, `SELECT
			      (SELECT ts_end IS NULL FROM `+s+`.equipment_events_cpac_shadow WHERE id_equipment = 1001 AND ts_event = date_trunc('minute', now()) - interval '40 hours'),
			      (SELECT ts_end IS NULL AND duration = 60 FROM `+s+`.equipment_events_cpac_shadow WHERE id_equipment = 1002 AND cd_category = 'JUSTIFIED'),
			      (SELECT ts_end = date_trunc('minute', now()) - interval '29 hours' AND duration = 3599 FROM `+s+`.equipment_events_cpac_shadow
			        WHERE id_equipment = 1004 AND ts_event = date_trunc('minute', now()) - interval '30 hours' + interval '1 second')`).Scan(&stillOpen40, &human, &closed1004); err != nil {
				t.Fatal(err)
			}
			if !stillOpen40 || !human || !closed1004 {
				t.Errorf("rows the close pass must not touch changed: older backlog open=%v, human untouched=%v, closed untouched=%v",
					stillOpen40, human, closed1004)
			}
			if _, _, cls, err := RunOnceCPAC(ctx, d, cfg); err != nil || cls != 0 {
				t.Errorf("second tick closed %d rows (err %v), want 0", cls, err)
			}
		})
	}
}
