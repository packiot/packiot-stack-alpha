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

import "github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/caggsplit"

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
	hourValuesSplitSQL   = caggsplit.Spec{Temp: "hour_vals_snap", Tail: "SELECT * FROM sums", Feeds: []string{"sums"}}.MustSplit(hourValuesSQL)
	hourEventsSplitSQL   = caggsplit.Spec{Temp: "hour_ev_snap", Tail: "SELECT * FROM ev", Feeds: []string{"ev"}}.MustSplit(hourEventsSQL)
	hourLineLeadSplitSQL = caggsplit.Spec{Temp: "hour_ll_snap", Tail: lineLeadTail,
		Feeds: []string{"lines_p", "reconciled", "active"}}.MustSplit(hourLineLeadSQL)
	hourCountsAvailSplitSQL = caggsplit.Spec{Temp: "hour_ca_snap", Tail: countsAvailTail,
		Feeds: []string{"bounds", "active"}}.MustSplit(hourCountsAvailSQL)
	hourAvailFloorSplitSQL = caggsplit.Spec{Temp: "hour_af_snap", Tail: "SELECT * FROM active", Feeds: []string{"active"}}.MustSplit(hourAvailFloorSQL)

	shiftValuesSplitSQL   = caggsplit.Spec{Temp: "shift_vals_snap", Tail: "SELECT * FROM sums", Feeds: []string{"sums"}}.MustSplit(shiftValuesSQL)
	shiftLineLeadSplitSQL = caggsplit.Spec{Temp: "shift_ll_snap", Tail: lineLeadTail,
		Feeds: []string{"lines_p", "reconciled", "active"}}.MustSplit(shiftLineLeadSQL)
	shiftCountsAvailSplitSQL = caggsplit.Spec{Temp: "shift_ca_snap", Tail: countsAvailTail,
		Feeds: []string{"bounds", "active"}}.MustSplit(shiftCountsAvailSQL)
	shiftAvailFloorSplitSQL = caggsplit.Spec{Temp: "shift_af_snap", Tail: "SELECT * FROM active", Feeds: []string{"active"}}.MustSplit(shiftAvailFloorSQL)
)
