package uns

import (
	"strings"
	"testing"
)

func TestProvisionMatrixFidelity(t *testing.T) {
	// prod's upsert_features: equipment×6 plain + metrics special +
	// area×5; NO site provisioning.
	if len(provisionMatrix) != 11 {
		t.Errorf("matrix size %d != 11", len(provisionMatrix))
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
