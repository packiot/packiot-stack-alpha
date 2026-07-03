package reports

import (
	"strings"
	"testing"
)

func TestBoxes13Fidelity(t *testing.T) {
	for _, m := range []string{
		"Label_Neopac", "id_enterprise = 13", "id_equipment = 0",
		"interval '12 hour'", `PT(\d+)H(\d+)M(\d+)S`,
		"AT TIME ZONE 'Europe/Zurich'", "cd_equipment = ln.workcenter",
		"ON CONFLICT (ts_value, id_order)",
	} {
		if !strings.Contains(boxes13SQL, m) {
			t.Errorf("boxes13 lost rule: %q", m)
		}
	}
}
