package writers

import (
	"os"
	"strings"
	"testing"
)

// Port-fidelity guards for parameter 30850 (ADR-0010 10.1).
func TestAnalogs30850SQLShape(t *testing.T) {
	for _, m := range []string{"analogs", "ON CONFLICT (ts_value, id_equipment)"} {
		if !strings.Contains(analogsUpsertSQL, m) {
			t.Errorf("analogs SQL lost: %q", m)
		}
	}
}

// 30850 sits INSIDE the 30800-30899 skip range: its case must dispatch
// first or the port silently regresses to a skip counter.
func TestAnalogsDispatchPrecedesRangeSkip(t *testing.T) {
	src, err := os.ReadFile("po_parameter.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	i, j := strings.Index(s, "case id == 30850"), strings.Index(s, "id >= 30800 && id <= 30899")
	if i < 0 || j < 0 || i > j {
		t.Errorf("case 30850 must appear before the 30800-30899 range skip (i=%d j=%d)", i, j)
	}
}
