package uns

import (
	"fmt"
	"strings"
	"testing"
)

func TestProvisionMatrixFidelity(t *testing.T) {
	// equipment×6 plain + metrics special + area×2 (day, shift). #186 retired the
	// area live hour/week/month grains, so provisioning drops to 8; NO site provisioning.
	if len(provisionMatrix) != 8 {
		t.Errorf("matrix size %d != 8", len(provisionMatrix))
	}
	for _, m := range provisionMatrix {
		if strings.HasPrefix(m.unsTable, "uns_site") {
			t.Error("prod provisions no site tables — faithful port must not either")
		}
	}
}

func TestRefreshShape(t *testing.T) {
	for _, m := range []string{
		"tp_equipment > 1",
		"id_area = ANY($1)", "id_enterprise = ANY($2)",
		"date_trunc('%[3]s', now())::date",
		"agg_equipment_values_1hour",
	} {
		if !strings.Contains(refreshEquipmentSQL, m) {
			t.Errorf("refresh lost %q", m)
		}
	}
	for _, banned := range []string{"= 24", "(2,30,34"} {
		if strings.Contains(refreshEquipmentSQL, banned) {
			t.Errorf("hardcoded exclusion %q — must come from shared config", banned)
		}
	}
}

// TestEquipmentShiftDayShape guards the grey-tile unfreeze refreshers:
// same population/exclusion contract as the working equipment grains,
// sourced from the runtime tables, and each ADVANCES last_updated so
// the frozen freshness timestamp moves.
func TestEquipmentShiftDayShape(t *testing.T) {
	// day: sourced from equipment_oee_daily at today's bucket.
	for _, m := range []string{
		"equipment_oee_daily",
		"equipment_live_day",
		"date_trunc('day', now())::date",
		"tp_equipment > 1",
		"id_area = ANY($1)", "id_enterprise = ANY($2)",
		"last_updated = now()",
	} {
		if !strings.Contains(refreshDayEquipmentSQL, m) {
			t.Errorf("day refresh lost %q", m)
		}
	}
	// shift: current shift via the equipment shift-begin fn + prev1
	// block; prev1 LEFT-joined so the current tile advances even with
	// no prior shift row.
	for _, m := range []string{
		"equipment_oee_shift",
		"equipment_live_shift",
		"piot_get_shift_hour_begin_by_equipment",
		"tp_equipment > 1",
		"prev1_oee = p1.oee",
		"LEFT JOIN prod1 p1",
		"last_updated = now()",
	} {
		if !strings.Contains(refreshShiftEquipmentSQL, m) {
			t.Errorf("shift refresh lost %q", m)
		}
	}
	// no hardcoded id scoping (standing directive).
	for _, banned := range []string{"(2,30,34", "id_enterprise IN ("} {
		if strings.Contains(refreshDayEquipmentSQL+refreshShiftEquipmentSQL, banned) {
			t.Errorf("hardcoded id scoping %q must not appear", banned)
		}
	}
}

// TestEquipmentFreshnessStamp guards the hour/week/month/job unfreeze:
// each equipment-grain refresher must ADVANCE last_updated so the
// mission-control tile's freshness signal moves off the Provision seed
// time (the frozen-tile recurrence — same class as the shift/day gap).
func TestEquipmentFreshnessStamp(t *testing.T) {
	cases := []struct {
		name, sql string
	}{
		{"hour", refreshHourEquipmentSQL},
		{"week/month", refreshEquipmentSQL},
		{"job", refreshJobsSQL},
	}
	for _, c := range cases {
		if !strings.Contains(c.sql, "last_updated") || !strings.Contains(c.sql, "now()") {
			t.Errorf("%s refresher must stamp last_updated = now() (frozen-tile guard)", c.name)
		}
	}
}

// TestEquipmentShiftDaySQLBuilds ensures both statements schema-qualify
// cleanly with no leftover Sprintf verbs for both flow layouts.
func TestEquipmentShiftDaySQLBuilds(t *testing.T) {
	// [ev, ref, grain] — the grain-sink schema (equipment_live_*) is now a
	// separate arg (t237 GrainSchema knob; flips public→silver at P-silver).
	for _, schemas := range [][3]string{
		{"shadow_go_port", "public", "shadow_go_port"}, // F2 comparator layout
		{"public", "public", "public"},                 // single-flow F3-native
		{"public", "public", "silver"},                 // staging post P-silver
	} {
		for _, q := range []string{refreshDayEquipmentSQL, refreshShiftEquipmentSQL} {
			out := fmt.Sprintf(q, schemas[0], schemas[1], schemas[2])
			if strings.Contains(out, "%!") || strings.Contains(out, "%[") {
				t.Errorf("Sprintf verb residue for %v", schemas)
			}
		}
	}
}
