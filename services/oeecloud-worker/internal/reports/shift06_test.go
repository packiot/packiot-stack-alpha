package reports

import (
	"strings"
	"testing"
)

func TestShift06PortFidelity(t *testing.T) {
	for _, m := range []string{"customer_id = 6", "America/Montreal", "interval '21 day'"} {
		if !strings.Contains(shift06Delete, m) {
			t.Errorf("delete lost rule: %q", m)
		}
	}
	for _, m := range []string{"customer_reports.shift", "SELECT 6,",
		"get_report_shift_enterprsie_06c(", "index2", "discart_h"} {
		if !strings.Contains(shift06Insert, m) {
			t.Errorf("insert lost rule: %q", m)
		}
	}
	if strings.Contains(shift06Insert, "get_report_shift_enterprsie_06()") {
		t.Error("must NOT call the dead plain-06 generation")
	}
}
