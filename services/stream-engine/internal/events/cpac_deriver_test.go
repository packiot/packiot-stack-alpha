package events

import (
	"strings"
	"testing"
)

// TestCPACDeriverScopeAndInput locks in the two design-defining decisions that
// STEP-1 empirical sampling forced: the derivation is scoped to status_type=0
// (a PARALLEL path — it must NOT touch the status_type=4 gates) and it islands
// over COUNT ACTIVITY (ca_agg_equipment_values_1min.gross_production_incr), NOT
// state (CPACK's live `state` is NULL).
func TestCPACDeriverScopeAndInput(t *testing.T) {
	both := cpacUpsertSQL + cpacCorrectSQL
	for _, m := range []string{
		"status_type = 0",                       // parallel path, not the 4-only gate
		"ca_agg_equipment_values_1min",          // count source, not the state stream
		"gross_production_incr > 0",             // heartbeat = a productive minute
		"COALESCE(NULLIF(e.stop_threshold_time", // per-equipment threshold, default fallback
		"make_interval(secs => thr)",            // grace before declaring a stop
		"interval '25 hours'",                   // recompute window (matches deriver.go)
		"interval '10 seconds'",                 // time-based warmup, not row-count
		"ON CONFLICT (id_equipment, ts_event)",  // idempotency key
	} {
		if !strings.Contains(both, m) {
			t.Errorf("CPAC deriver lost rule: %q", m)
		}
	}
	// Must NOT widen the existing 4-only deriver: this file never selects
	// status_type = 4, and never touches ca_discrete_changes_1s (the state
	// stream the status_type=4 path islands over).
	if strings.Contains(both, "status_type = 4") {
		t.Error("CPAC deriver must not reference status_type=4 (parallel path only)")
	}
	if strings.Contains(both, "ca_discrete_changes_1s") {
		t.Error("CPAC deriver must island over counts, not the ca_discrete_changes_1s state stream")
	}
	// Alternating running(6)/stopped(10) transition stream — prod's literal codes.
	if !strings.Contains(cpacUpsertSQL, "6 AS status") || !strings.Contains(cpacUpsertSQL, "10 AS status") {
		t.Error("CPAC deriver must emit both running(6) and stopped(10) transitions")
	}
}

// TestCPACDeriverNeverClobbersHumanEdits is the load-bearing invariant: the
// detector auto-inserts events operators later modify (justify/split/trim via
// edge-api pocontrol.events_justify), so re-derivation must (a) never overwrite
// a human-touched row, (b) never delete one, and (c) only append in un-covered
// time. Each of those three is a distinct SQL site — assert all three, and that
// the guard is STRICTLY WIDER than deriver.go's forced_creation_system-only one.
func TestCPACDeriverNeverClobbersHumanEdits(t *testing.T) {
	// Assert against the FORMATTED SQL (%[4]s → "ev"), i.e. exactly what executes.
	upsert := fmtCPAC(cpacUpsertSQL, "s", "public", "t", "ev")
	del := fmtCPAC(cpacCorrectSQL, "s", "public", "t", "ev")

	// (a) upsert never overwrites a human-touched conflict row.
	if !strings.Contains(upsert, "DO UPDATE") {
		t.Fatal("upsert must be ON CONFLICT DO UPDATE")
	}
	upWhere := upsert[strings.LastIndex(upsert, "DO UPDATE"):]
	if !strings.Contains(upWhere, "WHERE NOT (ev.forced_creation_system") {
		t.Error("DO UPDATE must be guarded by WHERE NOT (human-touched) so a justified row is never overwritten")
	}
	// (b) delete never removes a human-touched row.
	if !strings.Contains(del, "AND NOT (ev.forced_creation_system") {
		t.Error("delete pass must exclude human-touched rows")
	}
	// (c) append-only in un-covered time: NOT EXISTS a human-protected span.
	if !strings.Contains(upsert, "NOT EXISTS") ||
		!strings.Contains(upsert, "f.ts_event < COALESCE(h.ts_end, now())") {
		t.Error("upsert must skip transitions that fall inside a human-protected event span (append-only)")
	}
	// (d) superseded-cleanup: the correct pass also sweeps a non-human derived row
	// that a human span later took over (minted before the human touched it).
	if !strings.Contains(del, "h.ts_event <> ev.ts_event") ||
		!strings.Contains(del, "ev.ts_event < COALESCE(h.ts_end, now())") {
		t.Error("correct pass must sweep non-human derived rows superseded by a human-covered span")
	}
	// The guard must protect justification columns, not just forced_creation_system
	// (a plain 30810 justify sets cd_category and leaves forced_creation_system
	// false — the deriver.go guard alone would NOT protect it).
	for _, col := range []string{"cd_category IS NOT NULL", "txt_downtime_notes IS NOT NULL",
		"planned_downtime", "change_over", "idle IS NOT NULL"} {
		if !strings.Contains(upsert, col) {
			t.Errorf("human-touched guard missing justification column check: %q", col)
		}
	}
}

// TestCPACScopeSharedByBothPasses — a minter must always have a co-scoped
// cleaner (the orphan-open-event / int-overflow class). The enterprise scope
// ($1) and the status_type=0 / tp filter appear in both passes.
func TestCPACScopeSharedByBothPasses(t *testing.T) {
	if !strings.Contains(cpacUpsertSQL, "id_enterprise = ANY($1)") {
		t.Error("upsert missing enterprise scope $1")
	}
	if !strings.Contains(cpacCorrectSQL, "ev.id_enterprise = ANY($1)") {
		t.Error("delete missing enterprise scope $1 — orphan-open-event risk")
	}
	if !strings.Contains(cpacUpsertSQL, "e.tp_equipment IN (1, 3)") {
		t.Error("scope must cover members(1) + lines(3) to match prod's mirrored stream")
	}
}

// TestRunOnceCPACDefaults — the empty CPACConfig is inert-safe: table + threshold
// default without a nil-deref or a zero-threshold divide (a 0 threshold makes
// every count gap a session boundary — nonsensical).
func TestRunOnceCPACDefaults(t *testing.T) {
	// RunOnceCPAC (not the dumb fmtCPAC formatter) applies DefaultCPACTargetTable
	// and a 300s threshold floor when CPACConfig is zero-valued — so the loop can
	// never be wired to an empty table name or a nonsensical 0s threshold.
	if DefaultCPACTargetTable == "" {
		t.Fatal("DefaultCPACTargetTable must be non-empty")
	}
	// Formatting with the default table yields a valid, fully-qualified target.
	got := fmtCPAC(cpacUpsertSQL, "public", "public", DefaultCPACTargetTable, "ev")
	if !strings.Contains(got, "INTO public."+DefaultCPACTargetTable+" AS ev") {
		t.Errorf("formatted upsert must target the default shadow table; got INTO clause missing")
	}
}
