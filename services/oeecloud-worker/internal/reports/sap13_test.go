package reports

import (
	"strings"
	"testing"
)

// Port-fidelity guard for the sap13 verbatim embed (same discipline as
// speed33_test.go): the business rules captured from prod must survive
// any future edit, and the three surgical transforms must stay intact.
func TestSap13PortFidelity(t *testing.T) {
	mustContain := []string{
		// pool contract (issue #223 — back4-api targets the same key)
		"INSERT INTO customer_reports.sap_data_sync",
		"ON CONFLICT (customer_id, linie, tag, shicht, auftrag_key)",
		"__CUSTOMER_ID__ AS customer_id",
		// frozen business rules from the prod capture
		"Europe/Zurich",
		"SELECT DISTINCT ON (linie, tag, shicht, auftrag_key)",
		"COALESCE(auftrag, 0) AS auftrag_key",
		"sum_labels as gutmenge",
		"interval '5 day'",
	}
	for _, s := range mustContain {
		if !strings.Contains(sap13Body, s) {
			t.Errorf("sap13 body lost a frozen rule/transform: %q", s)
		}
	}

	// The WRITE target must be the pool — never the legacy table. The
	// legacy name may appear only in comments/reads (frozen names).
	if strings.Contains(sap13Body, "INSERT INTO sap_report_data_sync_customer_13") {
		t.Error("sap13 body writes the legacy table — pool swap regressed")
	}

	// New-code rule: no hardcoded tenant in the projection — the
	// placeholder must be substituted at run time from config.
	if !strings.Contains(sap13Body, "__CUSTOMER_ID__") {
		t.Error("customer_id placeholder missing — tenant got hardcoded")
	}
}
