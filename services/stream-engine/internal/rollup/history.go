// history.go — renders the engine's OWN hour/shift/day passes as one per-day SQL
// script for repairing gold history older than the live engine windows.
//
// Why this exists: every engine pass has its own lookback (hour backfill 10 d,
// shift line-lead + oee-reconcile 25 d, shift eligible 30 d, day eligible
// 1 month). Re-flagging rows older than a pass's window triggers only the passes
// that still cover them, which leaves a MIXED state — e.g. on 2026-10-01 the
// state-only shift pass rewrote >25-day-old line shifts as "running the whole
// time" while the line-lead pass that should override it skipped them. A history
// repair therefore has to run every pass, widened to the repair horizon, in one
// transaction per day.
//
// Until this file the repair SQL was rendered by a throwaway test in a session
// scratchpad and widened with sed — so the next repair would have started from a
// stale copy of the engine. RenderHistoryRecompute builds the script from the
// SAME step lists RunHourBackfill / RunShift / RunDay execute (hourBackfillSteps,
// shiftSteps, daySteps), so it can never drift from the code it ships with.
//
// The rendered template has three placeholders, filled per day by
// scripts/recompute/run-day-recompute.sh:
//
//	__FROM__ / __TO__   the UTC day window (timestamptz literals)
//	-- @@FLAG_SQL@@     the operator's scope SQL (sets recalc_needed=true on the
//	                    hour + shift rows to rebuild, INSIDE the same transaction
//	                    so no live pass can drain them half-way)
//	__END__             COMMIT or ROLLBACK (dry run); left unfilled, psql errors
//	                    on it and the transaction aborts — a raw template never
//	                    commits by accident.
//
// See docs/runbooks/history-recompute.md.
package rollup

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

const (
	HistoryFromPlaceholder = "__FROM__"
	HistoryToPlaceholder   = "__TO__"
	HistoryFlagMarker      = "-- @@FLAG_SQL@@"
	HistoryEndPlaceholder  = "__END__"

	// HistoryMinHorizonDays: below the widest live window (shift eligible,
	// 30 d) the "widening" would NARROW a pass. HistoryMaxHorizonDays: the LOCF
	// chunk bounds widen to horizon+7 and must stay inside the 90-day literal
	// the speed/minute scans keep (hour.go / shift.go `m.ts_value >= now()-90d`).
	HistoryMinHorizonDays = 30
	HistoryMaxHorizonDays = 83
)

// HistoryRecompute is the engine configuration a rendered script must match.
// Build it from the SAME env the running worker uses (cmd/recompute-render).
type HistoryRecompute struct {
	Dest                    flows.Dest // Name + schemas; Pool is unused
	CA                      CountersAvail
	ChangeoverAvailability  bool
	ExclAreas               []int
	ExclEnterprises         []int
	MachineLevelEnterprises []int
	HorizonDays             int    // oldest recomputable row age; default 75
	StatementTimeout        string // per statement; default 900s
	BatchLimit              int    // eligible-set LIMIT; default 100000 (one day never binds)
}

// historyLeftoverOK lists the `now() - interval` literals the renderer must
// deliberately NOT widen. Anything else left un-widened fails the render, so a
// new window added to the engine forces a decision here instead of silently
// turning into a cliff inside a repair.
var historyLeftoverOK = map[string]string{
	"65 minutes": "hour eligible UPPER bound (the live RunHour owns the last 65 min)",
	"2 day":      "count-floor / counters-avail: bounded to where the 1-min cagg is guaranteed materialized",
	"2 days":     "count-floor / counters-avail: bounded to where the 1-min cagg is guaranteed materialized",
	"90 days":    "speed scans over the 1-min cagg (fixed; above every horizon)",
}

var (
	nowMinusInterval = regexp.MustCompile(`now\(\) - interval '([^']+)'`)
	bindParam        = regexp.MustCompile(`\$([0-9]+)\b`)
)

// widenForHistory stretches every live recency window of a rendered step to the
// repair horizon. Like widenHourWindows, it changes WHICH rows a pass touches,
// never how a touched row is computed (every pass is anchored on the eligible
// row's own ts_value). LOCF chunk bounds keep their 7-day look-back slack.
func widenForHistory(sql string, horizonDays int) string {
	h := fmt.Sprintf("now() - interval '%d days'", horizonDays)
	locf := fmt.Sprintf("now() - interval '%d days'", horizonDays+7)
	return strings.NewReplacer(
		"now() - interval '6 hour'", h,
		"now() - interval '10 days'", h,
		"now() - interval '25 days'", h,
		"now() - interval '25 day'", h,
		"now() - interval '30 days'", h,
		"now() - interval '30 day'", h,
		"now() - interval '1 month'", h,
		// LOCF lookups for the ideal speed: hour backfill 17 d (= 10 + 7),
		// shift 37 d (= 30 + 7).
		"now() - interval '17 days'", locf,
		"now() - interval '37 days'", locf,
	).Replace(sql)
}

// sqlIntArray renders ids as an int[] literal for the inlined bind params.
func sqlIntArray(ids []int) string {
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = strconv.Itoa(id)
	}
	return "'{" + strings.Join(parts, ",") + "}'::int[]"
}

// inlineBinds replaces $1..$n with int[] literals (the eligible statements are
// the only parameterized ones; psql scripts have no bind params).
func inlineBinds(sql string, args ...[]int) (string, error) {
	var err error
	out := bindParam.ReplaceAllStringFunc(sql, func(m string) string {
		n, _ := strconv.Atoi(m[1:])
		if n < 1 || n > len(args) {
			err = fmt.Errorf("unexpected bind %s", m)
			return m
		}
		return sqlIntArray(args[n-1])
	})
	return out, err
}

// boundToWindow narrows an eligible statement to the day being repaired by
// inserting the window predicate right before its ORDER BY (or at the end).
func boundToWindow(sql, col string) (string, error) {
	pred := fmt.Sprintf("\n\t AND %s >= '%s' AND %s < '%s'", col, HistoryFromPlaceholder, col, HistoryToPlaceholder)
	const orderBy = "\n\t ORDER BY"
	switch strings.Count(sql, orderBy) {
	case 0:
		return sql + pred, nil
	case 1:
		return strings.Replace(sql, orderBy, pred+orderBy, 1), nil
	default:
		return "", fmt.Errorf("eligible statement has %d ORDER BY clauses — cannot bound it", strings.Count(sql, orderBy))
	}
}

func (h *HistoryRecompute) defaults() error {
	if h.HorizonDays == 0 {
		h.HorizonDays = 75
	}
	if h.HorizonDays < HistoryMinHorizonDays || h.HorizonDays > HistoryMaxHorizonDays {
		return fmt.Errorf("horizon %d days outside [%d, %d]", h.HorizonDays, HistoryMinHorizonDays, HistoryMaxHorizonDays)
	}
	if h.StatementTimeout == "" {
		h.StatementTimeout = "900s"
	}
	if h.BatchLimit == 0 {
		h.BatchLimit = 100000
	}
	if h.Dest.Name == "" || h.Dest.GoldSchema == "" {
		return fmt.Errorf("dest name/schemas not set")
	}
	return nil
}

// RenderHistoryRecompute returns the per-day template (see file header).
func RenderHistoryRecompute(h HistoryRecompute) (string, error) {
	if err := h.defaults(); err != nil {
		return "", err
	}
	d := h.Dest
	var b strings.Builder
	stmt := func(s string) { b.WriteString(strings.TrimRight(s, " \t\n;")); b.WriteString(";\n") }

	hourElig, err := inlineBinds(fmtRD(hourBackfillEligibleSQL, d, h.BatchLimit), h.ExclAreas, h.ExclEnterprises)
	if err != nil {
		return "", fmt.Errorf("hour eligible: %w", err)
	}
	if hourElig, err = boundToWindow(hourElig, "h.ts_value"); err != nil {
		return "", fmt.Errorf("hour eligible: %w", err)
	}
	shiftElig, err := inlineBinds(fmtRD(shiftEligibleSQL, d, h.BatchLimit), h.ExclAreas, h.ExclEnterprises, h.MachineLevelEnterprises)
	if err != nil {
		return "", fmt.Errorf("shift eligible: %w", err)
	}
	if shiftElig, err = boundToWindow(shiftElig, "e.ts_value"); err != nil {
		return "", fmt.Errorf("shift eligible: %w", err)
	}
	// The day pass is NOT bounded to the window: it drains every flagged day in
	// the horizon, including the ones cascade-day just flagged (whose production
	// day can start before __FROM__ when day_begin is not midnight UTC).
	dayElig, err := inlineBinds(fmt.Sprintf(dayEligibleSQL, d.GoldSchema, d.RefSchema), h.ExclAreas, h.ExclEnterprises)
	if err != nil {
		return "", fmt.Errorf("day eligible: %w", err)
	}

	fmt.Fprintf(&b, "-- History recompute template — rendered by cmd/recompute-render from the engine's\n")
	fmt.Fprintf(&b, "-- hourBackfillSteps / shiftSteps / daySteps. DO NOT EDIT; re-render from current code.\n")
	fmt.Fprintf(&b, "-- dest=%s horizon=%dd line_lead=%v ents=%v opt_in=%v opt_out=%v counters_avail=%v eq=%v\n",
		d.Name, h.HorizonDays, h.CA.engagedLineLead(), h.CA.LineLeadEnterprises, h.CA.LineLeadOptIn, h.CA.LineLeadOptOut, h.CA.engaged(), h.CA.Equipments)
	fmt.Fprintf(&b, "-- floor=%v canonical=%v exclusions=%v changeover_avail=%v excl_areas=%v excl_ents=%v machine_level=%v\n",
		h.CA.engagedFloor(), h.CA.engagedCanonical(), h.CA.engagedExclusions(), h.ChangeoverAvailability, h.ExclAreas, h.ExclEnterprises, h.MachineLevelEnterprises)
	stmt("BEGIN")
	stmt(fmt.Sprintf("SET LOCAL statement_timeout = '%s'", h.StatementTimeout))
	// Row-level decompression of the touched gold rows (NOT decompress_chunk).
	stmt("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0")
	// Blocking (not try) locks: the repair waits for the engine's current tick,
	// then holds both keys so neither the backfill nor the live rollup can
	// interleave with this day.
	stmt(fmt.Sprintf("SELECT pg_advisory_xact_lock(hashtextextended('%s:runtime-backfill', 0))", d.Name))
	stmt(fmt.Sprintf("SELECT pg_advisory_xact_lock(hashtextextended('%s:runtime', 0))", d.Name))
	b.WriteString(HistoryFlagMarker + "\n")

	// ── hour grain (RunHourBackfill) ──
	stmt(widenForHistory(hourElig, h.HorizonDays))
	stmt("CREATE INDEX ON hour_elig (id_equipment, ts_value)")
	stmt("ANALYZE hour_elig")
	stmt("SELECT 'n_hour_elig', count(*) FROM hour_elig")
	for _, s := range hourBackfillSteps(d, h.CA, h.ChangeoverAvailability) {
		fmt.Fprintf(&b, "-- hour: %s\n", s.name)
		stmt(widenForHistory(s.sql, h.HorizonDays))
	}
	stmt("DROP TABLE hour_elig")

	// ── shift grain (RunShift, minus the live-tail reflag) ──
	stmt(widenForHistory(shiftElig, h.HorizonDays))
	stmt("CREATE INDEX ON shift_elig (id_equipment, ts_value)")
	stmt("ANALYZE shift_elig")
	stmt("SELECT 'n_shift_elig', count(*) FROM shift_elig")
	for _, s := range shiftSteps(d, h.CA, h.ChangeoverAvailability) {
		fmt.Fprintf(&b, "-- shift: %s\n", s.name)
		stmt(widenForHistory(s.sql, h.HorizonDays))
	}

	// ── day grain (RunDay, minus the live-tail reflag) ──
	stmt(widenForHistory(dayElig, h.HorizonDays))
	stmt("SELECT 'n_day_elig', count(*) FROM day_elig")
	for _, s := range daySteps(d, h.CA) {
		fmt.Fprintf(&b, "-- day: %s\n", s.name)
		stmt(widenForHistory(s.sql, h.HorizonDays))
	}
	stmt(HistoryEndPlaceholder)

	out := b.String()
	if err := checkHistoryWindows(out, h.HorizonDays); err != nil {
		return "", err
	}
	if m := bindParam.FindString(out); m != "" {
		return "", fmt.Errorf("rendered script still contains bind param %s", m)
	}
	return out, nil
}

// checkHistoryWindows fails on any `now() - interval` literal that is neither
// the horizon, the LOCF horizon, nor a documented deliberate exception.
func checkHistoryWindows(sql string, horizonDays int) error {
	ok := map[string]bool{
		fmt.Sprintf("%d days", horizonDays):   true,
		fmt.Sprintf("%d days", horizonDays+7): true,
	}
	for k := range historyLeftoverOK {
		ok[k] = true
	}
	bad := map[string]bool{}
	for _, m := range nowMinusInterval.FindAllStringSubmatch(sql, -1) {
		if !ok[m[1]] {
			bad[m[1]] = true
		}
	}
	if len(bad) == 0 {
		return nil
	}
	var list []string
	for k := range bad {
		list = append(list, "'"+k+"'")
	}
	sort.Strings(list)
	return fmt.Errorf("un-widened engine window(s) %s: add them to widenForHistory or historyLeftoverOK", strings.Join(list, ", "))
}
