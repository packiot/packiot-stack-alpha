// cagg_split.go — every rollup DML that reads a real-time cagg, split into a read
// planned as a SELECT and the unchanged DML (ADR-0063 Phase A2; see package
// internal/caggsplit for the mechanism and the TimescaleDB watermark trap).
//
// Measured on staging 2026-10-14 (stream_engine, packiot_analytics):
//
//	shift values (shiftValuesSQL, equipment_categorical_1hour): 63 eligible rows,
//	  the read as a SELECT 0.68 s; inside the UPDATE planned at cost 2.55e8 and ran
//	  250-296 s. From the 21:47 deploy on, EVERY runtime-rollup tick hit its 300 s
//	  timeout in `shift values` or `shift line-lead` (15 in 3 h), so the shift grain
//	  stopped draining and the day/week/month/entity passes after it were cancelled.
//	shift/hour line-lead (equipment_categorical_1hour + _1min): 1.46 s mean, 11.9 s max.
//	hour events (last_seen over equipment_categorical_1hour): 1.58 s mean.
//	counters-avail / count-floor (equipment_categorical_1min): small today (a 5-
//	  equipment opt-in list) — same shape, so same fix before it grows.
//
// The ORIGINAL statement constants (hourValuesSQL, shiftValuesSQL, …) are left
// untouched: they are the reference the golden test (cagg_split_golden_test.go)
// compares the split form against, row for row, in one transaction. Every engine
// path and every parity/golden accessor uses the *Split* forms below.
package rollup

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/caggsplit"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// lineLeadTail joins the three CTEs the line-lead UPDATE reads into one row per
// (line_id, ts_value). lines_p has exactly one row per hour_elig/shift_elig row
// (the eligible tables are keyed by (id_equipment, ts_value) and equipments by
// id), reconciled one per lines row, active at most one (GROUP BY line_id,
// ts_value) — so the LEFT JOINs neither drop nor duplicate a row, and in the
// apply `reconciled` / `active` read back as the same columns with NULL where the
// original LEFT JOIN found no row.
const lineLeadTail = `SELECT l.*, r.eff_gross, r.eff_net, a.raw_running
	  FROM lines_p l
	  LEFT JOIN reconciled r ON r.line_id = l.line_id AND r.ts_value = l.ts_value
	  LEFT JOIN active a ON a.line_id = l.line_id AND a.ts_value = l.ts_value`

// countsAvailTail: the counters-only Availability UPDATE reads bounds b LEFT JOIN
// active a (bounds: one row per eligible key; active: at most one).
const countsAvailTail = `SELECT b.*, a.raw_running
	  FROM bounds b
	  LEFT JOIN active a ON a.id_equipment = b.id_equipment AND a.ts_value = b.ts_value`

var (
	hourValuesPass   = caggsplit.Spec{Temp: "hour_vals_snap", Tail: "SELECT * FROM sums", Feeds: []string{"sums"}}.MustPass(hourValuesSQL)
	hourEventsPass   = caggsplit.Spec{Temp: "hour_ev_snap", Tail: "SELECT * FROM ev", Feeds: []string{"ev"}}.MustPass(hourEventsSQL)
	hourLineLeadPass = caggsplit.Spec{Temp: "hour_ll_snap", Tail: lineLeadTail,
		Feeds: []string{"lines_p", "reconciled", "active"}}.MustPass(hourLineLeadSQL)
	hourCountsAvailPass = caggsplit.Spec{Temp: "hour_ca_snap", Tail: countsAvailTail,
		Feeds: []string{"bounds", "active"}}.MustPass(hourCountsAvailSQL)
	hourAvailFloorPass = caggsplit.Spec{Temp: "hour_af_snap", Tail: "SELECT * FROM active", Feeds: []string{"active"}}.MustPass(hourAvailFloorSQL)

	shiftValuesPass   = caggsplit.Spec{Temp: "shift_vals_snap", Tail: "SELECT * FROM sums", Feeds: []string{"sums"}}.MustPass(shiftValuesSQL)
	shiftLineLeadPass = caggsplit.Spec{Temp: "shift_ll_snap", Tail: lineLeadTail,
		Feeds: []string{"lines_p", "reconciled", "active"}}.MustPass(shiftLineLeadSQL)
	shiftCountsAvailPass = caggsplit.Spec{Temp: "shift_ca_snap", Tail: countsAvailTail,
		Feeds: []string{"bounds", "active"}}.MustPass(shiftCountsAvailSQL)
	shiftAvailFloorPass = caggsplit.Spec{Temp: "shift_af_snap", Tail: "SELECT * FROM active", Feeds: []string{"active"}}.MustPass(shiftAvailFloorSQL)

	// The #1775 hour speed split and the shift events bank were already
	// CREATE TEMP TABLE … AS forms; as Passes they get the session-table engine
	// form too (ADR-0063 A3).
	hourSpeedPass   = mustParseCTASPass(hourSpeedSQL, "hour_sp")
	shiftEventsPass = caggsplit.MustCTASPass(shiftEventsSQL, "shift_ev")

	// The self-contained text forms (psql scripts, parity/golden accessors).
	hourValuesSplitSQL       = hourValuesPass.SQL()
	hourEventsSplitSQL       = hourEventsPass.SQL()
	hourLineLeadSplitSQL     = hourLineLeadPass.SQL()
	hourCountsAvailSplitSQL  = hourCountsAvailPass.SQL()
	hourAvailFloorSplitSQL   = hourAvailFloorPass.SQL()
	shiftValuesSplitSQL      = shiftValuesPass.SQL()
	shiftLineLeadSplitSQL    = shiftLineLeadPass.SQL()
	shiftCountsAvailSplitSQL = shiftCountsAvailPass.SQL()
	shiftAvailFloorSplitSQL  = shiftAvailFloorPass.SQL()
)

// mustParseCTASPass reads a hand-written `DROP …; CREATE TEMP TABLE <t> ON COMMIT
// DROP AS <read>; <apply>` string (hourSpeedSQL) into a Pass, and checks that the
// Pass renders back to exactly that string.
func mustParseCTASPass(sql, table string) caggsplit.Pass {
	drop := "\n\tDROP TABLE IF EXISTS pg_temp." + table + ";"
	create := "\n\tCREATE TEMP TABLE " + table + " ON COMMIT DROP AS\n\t"
	if !strings.HasPrefix(sql, drop+create) {
		panic("mustParseCTASPass " + table + ": unexpected prefix")
	}
	rest := strings.TrimPrefix(sql, drop+create)
	i := strings.LastIndex(rest, ";\n\t")
	if i < 0 {
		panic("mustParseCTASPass " + table + ": no apply")
	}
	p := caggsplit.Pass{Table: table, Read: rest[:i], Apply: rest[i+len(";\n\t"):]}
	if p.SQL() != sql {
		panic("mustParseCTASPass " + table + ": does not round-trip")
	}
	return p
}

// rd returns a mapper that formats a template for d (fmtRD) with extras, for Pass.Map.
func rd(d flows.Dest, extra ...any) func(string) string {
	return func(s string) string { return fmtRD(s, d, extra...) }
}

// passStep is a rollup step backed by a Pass: the engine runs p.Run (session
// snapshot table + COPY), psql scripts and parity run sql (= p.SQL()).
func passStep(name string, p caggsplit.Pass) rollupStep {
	return rollupStep{name: name, sql: p.SQL(), pass: &p}
}

// execStep runs one step on tx in the engine form.
func execStep(ctx context.Context, tx pgx.Tx, s rollupStep) error {
	if s.pass != nil {
		_, err := s.pass.Run(ctx, tx)
		return err
	}
	_, err := tx.Exec(ctx, s.sql)
	return err
}

// fillElig (re)fills a session eligible table from its CREATE TEMP TABLE … AS
// template and returns the row count (ADR-0063 A3; see caggsplit.Pass).
func fillElig(ctx context.Context, tx pgx.Tx, table, ctas string, args ...any) (int64, error) {
	sel, err := caggsplit.CTASSelect(ctas, table)
	if err != nil {
		return 0, err
	}
	return caggsplit.Fill(ctx, tx, table, sel, args...)
}
