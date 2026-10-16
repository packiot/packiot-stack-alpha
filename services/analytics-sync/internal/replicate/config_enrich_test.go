package replicate

import "testing"

// CPACK (ent 3) keeps legacy ids by default; the +2M sandbox opts out.
func TestEnrichKeepLegacyIDsDefaultAndOverride(t *testing.T) {
	t.Setenv("RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS", "")
	if !Load().ReconcileEnrichKeepLegacyIDs {
		t.Fatal("default must keep legacy ids (CPACK ent-3 behavior unchanged)")
	}
	t.Setenv("RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS", "false")
	if Load().ReconcileEnrichKeepLegacyIDs {
		t.Fatal(`"false" must disable keep-legacy-ids (sandbox)`)
	}
}
