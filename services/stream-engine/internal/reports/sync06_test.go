package reports

import (
	"strings"
	"testing"
)

// The embedded body must remain the captured prod state machine: all
// numbered conditions present, the b-generation compute, the window
// literals, and no plpgsql wrapper remnants.
func TestSync06BodyFidelity(t *testing.T) {
	for _, m := range []string{
		"get_data_sync_enterprsie_06b(21)",
		"logics = 0", "1 as logics", "2 as logics", "4 as logics",
		"5 as logics", "6 as logics", "logics = 7", "logics = 9", "logics = 10",
		"trans_status", "to_delete",
		"interval '23 day'",
	} {
		if !strings.Contains(sync06BodyRaw, m) {
			t.Errorf("sync06 body lost %q", m)
		}
	}
	low := strings.ToLower(sync06BodyRaw)
	if strings.Contains(low, "end;") || strings.HasPrefix(strings.TrimSpace(low), "begin") {
		t.Error("plpgsql wrapper remnants must be stripped")
	}
}

// The tenant substitution must be bit-identical at the default config
// (verbatim guarantee) and complete when config diverges.
func TestSync06TenantSubstitution(t *testing.T) {
	if sync06Body(6, "") != sync06BodyRaw {
		t.Error("default config must render the verbatim capture bit-identically")
	}
	b := sync06Body(9, "customer_reports.production_sync")
	if strings.Contains(b, "id_enterprise = 6") || strings.Contains(b, "production_data_sync_enterprise_06") {
		t.Error("substitution incomplete for non-default tenant")
	}
	if !strings.Contains(b, "id_enterprise = 9") || !strings.Contains(b, "get_data_sync_enterprsie_09b(21)") {
		t.Error("substitution wrong for non-default tenant")
	}
}
