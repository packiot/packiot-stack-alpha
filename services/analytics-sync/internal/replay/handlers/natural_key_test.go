package handlers

import (
	"strings"
	"testing"
)

// Regression guards for bugs 247/248: every production_orders lifecycle
// UPDATE must target the natural key (id_enterprise, id_order) — never
// Flow 1's id_production_order, which lives in a different id space than
// the shadow rows. Every INSERT must qualify its ON CONFLICT target so
// unrelated constraint violations (e.g. the one-running-PO-per-equipment
// partial unique index) fail loudly instead of being swallowed.

func TestPOUpdatesTargetNaturalKey(t *testing.T) {
	updates := map[string]string{
		"sqlUpdatePOStop":    sqlUpdatePOStop,
		"sqlUpdatePOStart":   sqlUpdatePOStart,
		"sqlUpdatePOTsStart": sqlUpdatePOTsStart,
		"sqlUpdatePORecalc":  sqlUpdatePORecalc,
		"sqlClosePOChanged":  sqlClosePOChanged,
	}
	for name, sql := range updates {
		if !strings.Contains(sql, "id_enterprise = $") || !strings.Contains(sql, "id_order = $") {
			t.Errorf("%s: WHERE clause must target (id_enterprise, id_order):\n%s", name, sql)
		}
		if strings.Contains(sql, "WHERE id_production_order") {
			t.Errorf("%s: must not target Flow 1's id_production_order (bug 248):\n%s", name, sql)
		}
	}
}

func TestPOInsertsQualifyConflictTarget(t *testing.T) {
	inserts := map[string]string{
		"sqlInsertPORunning":   sqlInsertPORunning,
		"sqlInsertPOAvailable": sqlInsertPOAvailable,
		"sqlInsertPOChanged":   sqlInsertPOChanged,
	}
	for name, sql := range inserts {
		if !strings.Contains(sql, "ON CONFLICT (id_enterprise, id_order) DO NOTHING") {
			t.Errorf("%s: ON CONFLICT must be qualified with (id_enterprise, id_order) (bug 247):\n%s", name, sql)
		}
	}
}

// Event inserts must preserve Flow 1's id ($1 = id_equipment_event) and
// qualify their conflict target with ts_event — Flow 1's PK, so a
// conflict can only mean cursor re-replay. Unqualified ON CONFLICT is
// the bug-247 silent-loss pattern.
func TestEventInsertsPreserveIDAndQualifyConflict(t *testing.T) {
	inserts := map[string]string{
		"sqlInsertManualEvent": sqlInsertManualEvent,
		"sqlInsertSplitEvent":  sqlInsertSplitEvent,
	}
	for name, sql := range inserts {
		if !strings.Contains(sql, "id_equipment_event") {
			t.Errorf("%s: must insert Flow 1's id_equipment_event (id preservation):\n%s", name, sql)
		}
		if !strings.Contains(sql, "ON CONFLICT (ts_event) DO NOTHING") {
			t.Errorf("%s: ON CONFLICT must be qualified with (ts_event):\n%s", name, sql)
		}
	}
}
