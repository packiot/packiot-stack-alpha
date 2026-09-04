package rollup

import (
	"strings"
	"testing"
)

// Defect B correction fidelity guards (always-on, no DB): the
// not-metered-machine pass must null OEE for exactly the line-metered
// tp=1 rows and nothing else.
func TestUnmeteredShape(t *testing.T) {
	sql := unmeteredNullSQL
	for _, m := range []string{
		"oee = NULL, oee_a = NULL, oee_p = NULL, oee_q = NULL", // all four nulled
		"q.tp_equipment = 1",                                  // machines only
		"NOT (q.id_enterprise = ANY($1))",                     // NOT machine-level (the gate)
	} {
		if !strings.Contains(sql, m) {
			t.Errorf("unmetered pass lost %q", m)
		}
	}
	// Must NOT touch line (tp=3) or sector (tp=2) grains, and must be
	// idempotent (only touch rows that still carry a value).
	if strings.Contains(sql, "tp_equipment > 1") || strings.Contains(sql, "tp_equipment = 3") || strings.Contains(sql, "tp_equipment = 2") {
		t.Error("unmetered pass must scope to tp=1 machines only, never tp=2/3")
	}
	if !strings.Contains(sql, "oee IS NOT NULL") {
		t.Error("idempotency guard lost — pass must skip already-nulled rows")
	}
	// The gate must be the EXCLUSION (NOT ANY) of the machine-level set,
	// never an inclusion — including the set would null the machines that
	// ARE metered (the exact opposite of the fix).
	if strings.Contains(sql, "q.id_enterprise = ANY($1)") && !strings.Contains(sql, "NOT (q.id_enterprise = ANY($1))") {
		t.Error("gate must EXCLUDE the machine-level set, not include it")
	}
	// It must set NO count/time/state column — OEE columns only.
	for _, banned := range []string{"gross =", "net =", "running_time =", "available_time =", "recalc_needed"} {
		if strings.Contains(sql, banned) {
			t.Errorf("unmetered pass must touch ONLY the four OEE columns, found %q", banned)
		}
	}
}

// The table set must be the seven per-machine grain tables — never an
// area/site tier or the PO×shift join.
func TestUnmeteredTableSet(t *testing.T) {
	want := map[string]bool{
		"equipment_oee_hourly": true, "equipment_oee_daily": true,
		"equipment_oee_weekly": true, "equipment_oee_monthly": true,
		"equipment_oee_shift": true, "equipment_oee_shift_weekly": true,
		"equipment_oee_shift_monthly": true,
	}
	if len(unmeteredMachineTables) != len(want) {
		t.Fatalf("table set size = %d, want %d", len(unmeteredMachineTables), len(want))
	}
	for _, tbl := range unmeteredMachineTables {
		if !want[tbl] {
			t.Errorf("unexpected table in unmetered set: %q", tbl)
		}
		if strings.Contains(tbl, "area_") || strings.Contains(tbl, "site_") || strings.HasSuffix(tbl, "_job") {
			t.Errorf("non per-machine table in unmetered set: %q", tbl)
		}
	}
}
