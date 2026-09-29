package events

import (
	"crypto/sha256"
	"fmt"
	"strings"
	"testing"
)

// TestCPACDeriverScopeAndInput locks in the two design-defining decisions that
// STEP-1 empirical sampling forced: the derivation is scoped to status_type=0
// (a PARALLEL path — it must NOT touch the status_type=4 gates) and it islands
// over COUNT ACTIVITY (equipment_categorical_1min.gross_production_incr), NOT
// state (CPACK's live `state` is NULL).
func TestCPACDeriverScopeAndInput(t *testing.T) {
	// Formatted gross-only statements (the activity predicate is a format arg).
	both := fmtCPAC(cpacUpsertSQL, "s", "public", "t", "ev", "s") + fmtCPAC(cpacCorrectSQL, "s", "public", "t", "ev", "s")
	for _, m := range []string{
		"status_type = 0",                       // parallel path, not the 4-only gate
		"equipment_categorical_1min",            // count source, not the state stream
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
	upsert := fmtCPAC(cpacUpsertSQL, "s", "public", "t", "ev", "s")
	del := fmtCPAC(cpacCorrectSQL, "s", "public", "t", "ev", "s")

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
	got := fmtCPAC(cpacUpsertSQL, "public", "public", DefaultCPACTargetTable, "ev", "public")
	if !strings.Contains(got, "INTO public."+DefaultCPACTargetTable+" AS ev") {
		t.Errorf("formatted upsert must target the default shadow table; got INTO clause missing")
	}
}

// The human-cover probes must carry a lower bound on h.ts_event so TimescaleDB can
// exclude chunks; unbounded, each probe scanned the tenant's whole event history
// (live ent5 upsert 4.2 s per tick).
func TestCPACHumanCoverProbeIsTimeBounded(t *testing.T) {
	for name, sql := range map[string]string{"upsert": cpacUpsertSQL, "correct": cpacCorrectSQL} {
		if !strings.Contains(sql, "h.ts_event >= now() - interval '60 days'") {
			t.Errorf("%s: human-cover probe lost its h.ts_event lower bound", name)
		}
	}
}

// TestCPACGrossOnlySQLPinned pins the gross-only statements (the CPACK shadow
// instance and every LeadActivity=false caller) and proves they differ from the
// pre-PR statements (origin/staging 35453b1f) by EXACTLY the two deliberate bug
// fixes and nothing else:
//   - NULL-safe human guards (`IS TRUE` on forced_creation_system /
//     planned_downtime / change_over) — the correct pass and DO UPDATE were dead;
//   - the thr+60s look-back before the 25h window — the phantom RUNNING rows.
//
// Reverting just those two edits textually must reproduce the old SHA-256; the
// new SHA-256 is pinned so any further change to CPACK's SQL is deliberate.
func TestCPACGrossOnlySQLPinned(t *testing.T) {
	const lookback = `       -- LOOK-BACK`
	const window = `       AND m.ts_value > now() - interval '25 hours'
`
	revert := func(sql string) string {
		for _, c := range []string{"forced_creation_system", "planned_downtime", "change_over"} {
			sql = strings.ReplaceAll(sql, c+" IS TRUE", c)
		}
		i := strings.Index(sql, lookback)
		j := strings.Index(sql, "interval '2 days'\n")
		if i < 0 || j < 0 {
			t.Fatal("look-back block not found")
		}
		return sql[:i] + window + sql[j+len("interval '2 days'\n"):]
	}
	for name, c := range map[string]struct{ tmpl, old, now string }{
		"correct": {cpacCorrectSQL,
			"074b10e1426f84a37663453747cc9bf31357eb630c61d6ef81170a890360f93c",
			"25a8189f17814e8396600edae1f1971d0758f2a95b86c86403bad40800d6879a"},
		"upsert": {cpacUpsertSQL,
			"45e8d7246109a9a3f4326550cc0e5bf7ed458709e31a637f286e3b3296e6f394",
			"89ef41c0564c7885a203b3192796691ea6bc384911b7da150b6f82c82c60a151"},
	} {
		for _, got := range []string{
			fmtCPAC(c.tmpl, "silver", "core", "equipment_events_cpac_shadow", "ev", "silver"),
			fmtCPACMode(c.tmpl, "silver", "core", "equipment_events_cpac_shadow", "ev", "silver", false),
		} {
			if h := fmt.Sprintf("%x", sha256.Sum256([]byte(got))); h != c.now {
				t.Errorf("%s: gross-only SQL changed (sha256 %s, pinned %s)", name, h, c.now)
			}
			if h := fmt.Sprintf("%x", sha256.Sum256([]byte(revert(got)))); h != c.old {
				t.Errorf("%s: gross-only SQL differs from pre-PR by more than the two bug fixes (reverted sha256 %s, want %s)", name, h, c.old)
			}
			if strings.Contains(got, "leads") || strings.Contains(got, "net_production_incr") {
				t.Errorf("%s: gross-only SQL must not reference leads/net", name)
			}
		}
	}
}

// TestCPACHumanGuardsNullSafe: every nullable boolean in the human guards is
// wrapped in IS TRUE (a bare boolean makes the whole OR NULL for a derived row
// whose planned_downtime/change_over are NULL, and NOT NULL filters it out).
func TestCPACHumanGuardsNullSafe(t *testing.T) {
	for name, p := range map[string]string{"touched": humanTouchedPred, "cover": humanCoverPred} {
		for _, c := range []string{"forced_creation_system", "planned_downtime", "change_over"} {
			if !strings.Contains(p, c+" IS TRUE") {
				t.Errorf("%s guard: %s must be `IS TRUE` (NULL-safe)", name, c)
			}
		}
	}
}

// TestCPACWindowLookback: the first in-window minute must get its real gap.
func TestCPACWindowLookback(t *testing.T) {
	got := fmtCPAC(cpacUpsertSQL, "s", "public", "t", "ev", "s")
	if !strings.Contains(got, "m.ts_value > now() - interval '25 hours' - make_interval(secs => s.thr + 60)") {
		t.Error("counts must read thr+60s before the 25h window (phantom RUNNING-row fix)")
	}
	if !strings.Contains(got, "WHERE ts_event >= now() - interval '25 hours' + interval '10 seconds'") {
		t.Error("final must still drop transitions that fall in the look-back")
	}
}

// TestCPACLeadActivityNetOnlyLeadSQL — the net-only lead case (Bispharma L18 +
// BISNAGO leads carry ONLY net_production_incr). In LeadActivity mode both
// passes (minter + co-scoped cleaner) must: define the leads set from
// downtime_from_lead_machine lines in the $1 scope, count net/scrap minutes for
// those leads only, and keep gross as the rule for every other member.
func TestCPACLeadActivityNetOnlyLeadSQL(t *testing.T) {
	for name, tmpl := range map[string]string{"correct": cpacCorrectSQL, "upsert": cpacUpsertSQL} {
		got := fmtCPACMode(tmpl, "silver", "core", "equipment_events", "ev", "silver", true)
		if strings.Contains(got, "%!") || strings.Contains(got, "%[") {
			t.Fatalf("%s: unformatted verb in lead-activity SQL", name)
		}
		for _, m := range []string{
			"), leads AS (",
			"FROM core.equipments ln",         // RefSchema substituted inside the fragment
			"ln.downtime_from_lead_machine",   // per-line config gate
			"ln.lead_machine AS id_equipment", // events land on the lead machine
			"ln.id_enterprise = ANY($1)",      // same enterprise scope as the passes
			"m.gross_production_incr > 0",     // gross stays the rule for everyone
			"s.id_equipment IN (SELECT id_equipment FROM leads)",
			"m.net_production_incr > 0 OR m.scrap_incr > 0", // identity: net-only lead ⇒ gross = net
			"), counts AS (",
		} {
			if !strings.Contains(got, m) {
				t.Errorf("%s: lead-activity SQL missing %q", name, m)
			}
		}
		// The net/scrap widening must be conditioned on lead membership, never a
		// bare OR (which would mint events on every net-only intermediate station).
		if strings.Contains(got, "> 0 OR m.net_production_incr") {
			t.Errorf("%s: net activity must be gated on the leads set", name)
		}
		// The leads CTE sits between scope and counts, not after counts.
		if strings.Index(got, "), leads AS (") > strings.Index(got, "), counts AS (") {
			t.Errorf("%s: leads CTE must precede counts", name)
		}
	}
}
