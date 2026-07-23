package events

import (
	"strings"
	"testing"
)

func TestDeriverPortFidelity(t *testing.T) {
	both := upsertSQL + correctSQL
	for _, m := range []string{"interval '25 hours'", "interval '10 seconds'", "status_type = 4",
		"tp_equipment > 0", "ON CONFLICT (id_equipment, ts_event)",
		"interval '1 day'", "forced_creation_system", "ca_discrete_changes_1s"} {
		if !strings.Contains(both, m) {
			t.Errorf("port lost rule: %q", m)
		}
	}
	if strings.Contains(both, "gapfill") {
		t.Error("must not depend on the gapfill PL/pgSQL aggregate")
	}
	if !strings.Contains(upsertSQL, "first_value(state) OVER (PARTITION BY id_equipment, grp") {
		t.Error("LOCF gaps-and-islands rewrite missing")
	}
	if strings.Contains(both, "rn >") {
		t.Error("row-count warmup is wrong on sparse streams — must stay time-based")
	}
}

// TestWiderowStateScopeSharedAndGuarded asserts the ADR-0031 wide-row-state
// opt-in ($3) is present, applied IDENTICALLY to the minter (upsert) and the
// cleaner (correct/delete) passes, and restricted to tp=1 machines. A minter
// without a co-scoped cleaner is the orphan-open-event / int-overflow bug class.
func TestWiderowStateScopeSharedAndGuarded(t *testing.T) {
	// The widerow branch must appear in BOTH the upsert CTE and the correct
	// pass — same predicate, so every minted event has a cleaner in scope.
	widerowUpsert := strings.Contains(upsertSQL, "e.id_enterprise = ANY($3) AND e.tp_equipment = 1")
	widerowCorrect := strings.Contains(correctSQL, "id_enterprise = ANY($3) AND tp_equipment = 1")
	if !widerowUpsert {
		t.Error("widerow-state opt-in ($3, tp=1) missing from the upsert/minter pass")
	}
	if !widerowCorrect {
		t.Error("widerow-state opt-in ($3, tp=1) missing from the correct/cleaner pass — orphan-open-event risk")
	}
	// Native status_type=4 scope must survive alongside the opt-in.
	if !strings.Contains(upsertSQL, "e.status_type = 4 AND e.tp_equipment > 0") {
		t.Error("native status_type=4 scope lost from the upsert pass")
	}
	// The widerow branch must NOT admit lines (tp!=1) — line events aggregate
	// from members; deriving them from a wide-row double-counts.
	if strings.Contains(upsertSQL, "e.id_enterprise = ANY($3) AND e.tp_equipment > 0") {
		t.Error("widerow branch must be gated to tp_equipment = 1, not > 0 (line double-count guard)")
	}
}
