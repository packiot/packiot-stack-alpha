package main

import "testing"

// TestResolveFlow — the switch is fail-safe: only an explicit "f3" selects the
// shadow DB; everything else (unset, typo, empty, mixed-case) stays on f1 so a
// misconfig can never silently re-point reads at packiot_analytics.
func TestResolveFlow(t *testing.T) {
	cases := map[string]flow{
		"":     flowF1,
		"f1":   flowF1,
		"F3":   flowF1, // case-sensitive on purpose — only lowercase "f3" flips
		"f3 ":  flowF1, // no trimming — an exact match is required
		"prod": flowF1,
		"f3":   flowF3,
	}
	for in, want := range cases {
		if got := resolveFlow(in); got != want {
			t.Errorf("resolveFlow(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestDBNameForFlow — f1 targets packiot, f3 targets packiot_analytics. Defaults
// are the canonical pgbouncer pool names; the env overrides exist for a
// non-standard bring-up but must default correctly (a wrong default here would
// point the whole read plane at the wrong DB).
func TestDBNameForFlow(t *testing.T) {
	t.Setenv("DB_NAME", "")
	t.Setenv("DB_NAME_F3", "")
	if got := dbNameForFlow(flowF1); got != "packiot" {
		t.Errorf("dbNameForFlow(f1) = %q, want packiot", got)
	}
	if got := dbNameForFlow(flowF3); got != "packiot_analytics" {
		t.Errorf("dbNameForFlow(f3) = %q, want packiot_analytics", got)
	}
}

// TestActiveSQL_Dataset — a dataset with no sqlF3 serves its F1 sql on BOTH
// flows (the common case: F3 keeps F1's names). When an sqlF3 IS set, it is used
// ONLY under f3; f1 is byte-unchanged. This is the guarantee that merging the
// switch with default f1 changes nothing.
func TestActiveSQL_Dataset(t *testing.T) {
	noOverride := dataset{sql: "SELECT 1"}
	if got := noOverride.activeSQL(flowF1); got != "SELECT 1" {
		t.Errorf("f1 no-override = %q", got)
	}
	if got := noOverride.activeSQL(flowF3); got != "SELECT 1" {
		t.Errorf("f3 no-override must fall back to f1 sql, got %q", got)
	}
	withOverride := dataset{sql: "SELECT f1", sqlF3: "SELECT f3"}
	if got := withOverride.activeSQL(flowF1); got != "SELECT f1" {
		t.Errorf("f1 with-override must stay F1, got %q", got)
	}
	if got := withOverride.activeSQL(flowF3); got != "SELECT f3" {
		t.Errorf("f3 with-override must use F3, got %q", got)
	}
}

// TestActiveSQL_Endpoint — same contract for the fixed /v1/* endpoints.
func TestActiveSQL_Endpoint(t *testing.T) {
	ep := endpoint{sql: "SELECT f1", sqlF3: "SELECT f3"}
	if got := ep.activeSQL(flowF1); got != "SELECT f1" {
		t.Errorf("endpoint f1 = %q", got)
	}
	if got := ep.activeSQL(flowF3); got != "SELECT f3" {
		t.Errorf("endpoint f3 = %q", got)
	}
	plain := endpoint{sql: "SELECT only"}
	if got := plain.activeSQL(flowF3); got != "SELECT only" {
		t.Errorf("endpoint f3 no-override must fall back, got %q", got)
	}
}

// TestNoDatasetHasF3Override documents the live-census ground truth (2026-07-20):
// F3's divergence from F1 is ABSENCE, not RENAME, so no dataset needs a textual
// sqlF3 today. If a future rename lands one, this test is the tripwire that makes
// that a DELIBERATE, reviewed change (update the count + the flow.go note) rather
// than an accidental divergence.
func TestNoDatasetHasF3Override(t *testing.T) {
	for name, ds := range datasets {
		if ds.sqlF3 != "" {
			t.Errorf("dataset %q has an sqlF3 override — intended? update flow.go's "+
				"absence-not-rename note and the parity harness inventory if so", name)
		}
	}
	for _, ep := range endpoints {
		if ep.sqlF3 != "" {
			t.Errorf("endpoint %q has an sqlF3 override — see above", ep.path)
		}
	}
}
