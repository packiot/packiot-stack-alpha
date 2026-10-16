package reports

import (
	"strings"
	"testing"
)

// The embedded body must remain the captured prod state machine: all
// numbered conditions present, the b-generation compute, the window
// literals, and no plpgsql wrapper remnants. t244: the read source is
// the generic serving.data_sync and the write target is the multi-tenant
// pool customer_reports.production_data_sync (customer_id discriminator).
func TestSync06BodyFidelity(t *testing.T) {
	for _, m := range []string{
		"serving.data_sync(__ENTERPRISE__, 21)",
		"customer_reports.production_data_sync",
		"customer_id = __ENTERPRISE__",
		"logics = 0", "1 as logics", "2 as logics", "4 as logics",
		"5 as logics", "6 as logics", "logics = 7", "logics = 9", "logics = 10",
		"trans_status", "to_delete",
		"interval '23 day'",
	} {
		if !strings.Contains(sync06BodyRaw, m) {
			t.Errorf("sync06 body lost %q", m)
		}
	}
	// The per-enterprise-cloned read function and the per-enterprise-named
	// write target are the anti-pattern t244 kills — they must be gone.
	if strings.Contains(sync06BodyRaw, "get_data_sync_enterprsie") {
		t.Error("must NOT call the legacy per-enterprise clone get_data_sync_enterprsie_*")
	}
	if strings.Contains(sync06BodyRaw, "production_data_sync_enterprise_06") {
		t.Error("must NOT write the per-enterprise-named target production_data_sync_enterprise_06")
	}
	low := strings.ToLower(sync06BodyRaw)
	if strings.Contains(low, "end;") || strings.HasPrefix(strings.TrimSpace(low), "begin") {
		t.Error("plpgsql wrapper remnants must be stripped")
	}
}

// The tenant substitution replaces __ENTERPRISE__ with the id everywhere
// (serving.data_sync arg, customer_id fences, id_enterprise joins) and
// leaves no unsubstituted token behind.
func TestSync06TenantSubstitution(t *testing.T) {
	b6 := sync06Body(6)
	if strings.Contains(b6, "__ENTERPRISE__") {
		t.Error("token __ENTERPRISE__ left unsubstituted at enterprise 6")
	}
	for _, m := range []string{"serving.data_sync(6, 21)", "customer_id = 6"} {
		if !strings.Contains(b6, m) {
			t.Errorf("substitution incomplete at enterprise 6: missing %q", m)
		}
	}

	b9 := sync06Body(9)
	if strings.Contains(b9, "__ENTERPRISE__") {
		t.Error("token __ENTERPRISE__ left unsubstituted at enterprise 9")
	}
	for _, m := range []string{"serving.data_sync(9, 21)", "customer_id = 9"} {
		if !strings.Contains(b9, m) {
			t.Errorf("substitution wrong for enterprise 9: missing %q", m)
		}
	}
	// Anti-pattern kill: no per-tenant function-name cloning anywhere.
	if strings.Contains(b9, "get_data_sync_enterprsie") {
		t.Error("substitution must not resurrect the per-enterprise function clone")
	}
}
