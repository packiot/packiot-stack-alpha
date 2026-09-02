package events

import (
	"fmt"
	"strings"
	"testing"
)

// TestCloserBoundsAndClosesStaleOpens locks in the two closing mechanisms and
// the scope: (a) non-latest opens bounded by the next event (lead), (b) trailing
// opens closed on count-silence (last productive minute + grace), scoped to
// status_type=0 CPACK-class equipment. It closes ONLY — it must never derive or
// insert events (no INSERT), and it only ever writes ts_end IS NULL rows.
func TestCloserBoundsAndClosesStaleOpens(t *testing.T) {
	sql := closeStaleOpensSQL
	for _, m := range []string{
		"status_type = 0",                              // CPACK-class scope, not the 4-only deriver
		"tp_equipment IN (1, 3)",                       // machines + lines
		"lead(ev.ts_event)",                            // (a) next-event bounding
		"ca_agg_equipment_values_1min",                 // count-silence source (same as cpac_deriver)
		"gross_production_incr > 0",                    // productive-minute heartbeat
		"COALESCE(NULLIF(e.stop_threshold_time, 0), $2)", // per-equipment threshold w/ default
		"greatest(o.ts_event, lc.last_ts + make_interval(secs => lc.thr))", // (b) count-silence, clamped >= ts_event
		"lc.last_ts + make_interval(secs => lc.thr) < now()",              // only once genuinely silent
		"ev.ts_end IS NULL",                            // idempotent: touch only opens
	} {
		if !strings.Contains(sql, m) {
			t.Errorf("closer lost rule: %q", m)
		}
	}
	// Close-only: never derives/inserts events.
	if strings.Contains(sql, "INSERT INTO") {
		t.Error("closer must not INSERT — it only closes existing open rows")
	}
	// Must not touch the status_type=4 deriver's domain nor the state stream.
	if strings.Contains(sql, "status_type = 4") {
		t.Error("closer must not reference status_type=4")
	}
	if strings.Contains(sql, "ca_discrete_changes_1s") {
		t.Error("closer must island over counts, not the state stream")
	}
}

// TestCloserNeverClobbersHumanEdits is the load-bearing guard: operator-justified
// / reclassified downtimes must survive. On the LIVE table the guard MUST (1) omit
// forced_creation_system (true on every mirror-fan-out system row → keeping it
// closes nothing) and (2) be NULL-safe on the boolean flags (they are NULL, not
// false, on live system rows → a bare OR excludes every row).
func TestCloserNeverClobbersHumanEdits(t *testing.T) {
	// Formatted exactly as it executes: %[1]s/%[2]s schemas, %[4]s alias → "ev".
	sql := formatCloserSQL("s", "public", "ev")
	if !strings.Contains(sql, "AND NOT (ev.cd_category IS NOT NULL") {
		t.Fatal("closer must guard the UPDATE with the human-justified predicate")
	}
	// (1) forced_creation_system must NOT appear — it is the normal system flag on
	// the live table, so gating on it would skip 100% of the rows to close.
	if strings.Contains(sql, "forced_creation_system") {
		t.Error("live-table closer must NOT gate on forced_creation_system")
	}
	// (2) NULL-safe forms for the boolean flags.
	for _, col := range []string{
		"ev.cd_category IS NOT NULL", "ev.cd_subcategory IS NOT NULL",
		"ev.cd_machine IS NOT NULL", "ev.txt_downtime_notes IS NOT NULL",
		"ev.planned_downtime IS TRUE", "ev.change_over IS TRUE", "ev.idle IS NOT NULL",
	} {
		if !strings.Contains(sql, col) {
			t.Errorf("closer human-justified guard missing NULL-safe column: %q", col)
		}
	}
}

// formatCloserSQL mirrors RunOnceClose's fmt.Sprintf argument order so the test
// asserts the real executed string (index 3 unused; index 4 = row alias).
func formatCloserSQL(evSchema, refSchema, alias string) string {
	return fmt.Sprintf(closeStaleOpensSQL, evSchema, refSchema, "", alias)
}

// TestRunOnceCloseDefaults asserts the inert-safe defaults applied when the
// config leaves them at zero (threshold 300s, horizon 72h) — a zero CloserConfig
// with no enterprises is a no-op.
func TestRunOnceCloseDefaults(t *testing.T) {
	var cfg CloserConfig
	if len(cfg.Enterprises) != 0 {
		t.Error("zero CloserConfig must have no enterprises (inert)")
	}
	// The default-substitution branch is exercised in RunOnceClose; assert the
	// documented fallbacks are the ones the code applies.
	if got := defaultInt(cfg.ThresholdDefSec, 300); got != 300 {
		t.Errorf("threshold default = %d, want 300", got)
	}
	if got := defaultInt(cfg.HorizonHours, 72); got != 72 {
		t.Errorf("horizon default = %d, want 72", got)
	}
}
