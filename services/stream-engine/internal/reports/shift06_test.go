package reports

import (
	"strings"
	"testing"
)

func TestShift06PortFidelity(t *testing.T) {
	for _, m := range []string{"customer_id = $1", "America/Montreal", "interval '21 day'"} {
		if !strings.Contains(shift06Delete, m) {
			t.Errorf("delete lost rule: %q", m)
		}
	}
	for _, m := range []string{"customer_reports.shift", "SELECT $1::int,",
		"serving.report_shift($1,", "index2", "discart_h"} {
		if !strings.Contains(shift06Insert, m) {
			t.Errorf("insert lost rule: %q", m)
		}
	}
	// t244: the per-enterprise-cloned read function must be gone — the
	// generic serving.report_shift with $1=id_enterprise replaces it.
	if strings.Contains(shift06Insert, "get_report_shift_enterprsie") {
		t.Error("must NOT call the legacy per-enterprise clone get_report_shift_enterprsie_*")
	}
}
