package events

import (
	"strings"
	"testing"
)

func TestDeriverPortFidelity(t *testing.T) {
	both := upsertSQL + correctSQL
	for _, m := range []string{"interval '25 hours'", "rn > 10", "status_type = 4",
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
}
