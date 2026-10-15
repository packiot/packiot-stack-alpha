package config

import "testing"

// ADR-0064: PROD_MIRROR_ENTERPRISES folds a mirrored tenant out of every engine job that writes a reflected table.
func TestProdMirrorFoldsTenantOutOfWritingJobs(t *testing.T) {
	t.Setenv("PROD_MIRROR_ENTERPRISES", "5")
	t.Setenv("EVENTS_EXCLUDED_ENTERPRISES", "9")
	t.Setenv("PO_RECALC_EXCLUDED_ENTERPRISES", "")
	t.Setenv("CPAC_EVENT_LIVE_ENTERPRISES", "5")
	t.Setenv("CPAC_EVENT_ENTERPRISES", "3,5")
	t.Setenv("EVENTS_CLOSE_STALE_ENTERPRISES", "3,4,5,2000003")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	for name, got := range map[string]string{
		"EventsExcludedEnterprises":   c.EventsExcludedEnterprises,
		"PORecalcExcludedEnterprises": c.PORecalcExcludedEnterprises,
		"CPACEventLiveEnterprises":    c.CPACEventLiveEnterprises,
		"CPACEventEnterprises":        c.CPACEventEnterprises,
		"EventsCloseStaleEnterprises": c.EventsCloseStaleEnterprises,
	} {
		want := map[string]string{
			"EventsExcludedEnterprises":   "9,5",
			"PORecalcExcludedEnterprises": "6,5", // code default 6 kept
			"CPACEventLiveEnterprises":    "",
			"CPACEventEnterprises":        "3",
			"EventsCloseStaleEnterprises": "3,4,2000003",
		}[name]
		if got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if len(c.ProdMirrorEnterprises) != 1 || c.ProdMirrorEnterprises[0] != 5 {
		t.Fatalf("ProdMirrorEnterprises = %v", c.ProdMirrorEnterprises)
	}
}

func TestProdMirrorUnsetChangesNothing(t *testing.T) {
	t.Setenv("PROD_MIRROR_ENTERPRISES", "")
	t.Setenv("CPAC_EVENT_LIVE_ENTERPRISES", "5")
	t.Setenv("EVENTS_CLOSE_STALE_ENTERPRISES", "3,4,5,2000003")
	t.Setenv("EVENTS_EXCLUDED_ENTERPRISES", "")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.CPACEventLiveEnterprises != "5" || c.EventsCloseStaleEnterprises != "3,4,5,2000003" || c.EventsExcludedEnterprises != "" {
		t.Fatalf("unset must be byte-identical: %+v", c)
	}
}

func TestProdMirrorTypoFailsBoot(t *testing.T) {
	t.Setenv("PROD_MIRROR_ENTERPRISES", "5,x")
	if _, err := Load(); err == nil {
		t.Fatal("a typo must fail the boot, never silently disable the mirror")
	}
}
