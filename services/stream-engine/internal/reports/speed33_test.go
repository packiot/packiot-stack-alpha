package reports

import (
	"strings"
	"testing"
)

// Port-fidelity guards vs the captured prod procedure
// (0012-wave2-prod-writer-funcs.sql). The filters ARE the business
// rules — losing one silently changes which jobs get reported.
func TestSpeed33PortFidelity(t *testing.T) {
	musts := []string{
		"customer_reports.speed",         // pool target
		"SELECT $1::int,",                // customer_id column
		"tp_equipment = 3",               // line-level only
		"id_enterprise = $1",             // customer scope
		"INTERVAL '5 day'",               // rolling window
		"speed >= 150",                   // idle-speed floor
		"po.status > 2",                  // finished/paused POs only
		"net_production_val IS NOT NULL", // quality filter
		"NOT IN (SELECT id_order FROM customer_reports.speed WHERE customer_id = $1)", // pool-scoped dedupe
	}
	for _, m := range musts {
		if !strings.Contains(speed33SQL, m) {
			t.Errorf("port lost business rule: %q", m)
		}
	}
	if strings.Contains(speed33SQL, "report_speed_enterprsie_33") {
		t.Error("port must not touch the legacy table (dual-run isolation)")
	}
}
