package replicate

import (
	"strings"
	"testing"
)

func i64(v int64) *int64 { return &v }

// The UPDATE must fill only NULL columns: a value set in the new stack (an
// operator picking a product in the twin) is never overwritten by legacy.
func TestEnrichUpdateNeverOverwrites(t *testing.T) {
	for _, want := range []string{
		"COALESCE(po.id_product, u.id_product)",
		"COALESCE(po.id_client, u.id_client)",
		"po.id_product IS NULL AND u.id_product IS NOT NULL",
		"po.id_client IS NULL AND u.id_client IS NOT NULL",
		"po.id_enterprise = $1", // tenant-fenced
	} {
		if !strings.Contains(sqlEnrichUpdatePOs, want) {
			t.Errorf("sqlEnrichUpdatePOs missing %q", want)
		}
	}
}

// Dimensions resolve by the schema's natural keys, always tenant-scoped —
// never by a bare id (the twin's sequences sit at legacy's max, so ids alone
// could point a PO at a different product).
func TestEnrichResolvesByTenantNaturalKey(t *testing.T) {
	cases := map[string]string{
		"product": sqlEnrichFindProduct,
		"family":  sqlEnrichFindFamily,
		"client":  sqlEnrichFindClient,
	}
	for name, sql := range cases {
		if !strings.Contains(sql, "id_enterprise = $1") || !strings.Contains(sql, "nm_") {
			t.Errorf("%s lookup is not by (id_enterprise, name): %s", name, sql)
		}
		if strings.Contains(sql, "WHERE id_product =") || strings.Contains(sql, "WHERE id_client =") {
			t.Errorf("%s lookup trusts a bare id: %s", name, sql)
		}
	}
}

// Keeping a legacy id is only allowed when nobody holds it, and the sequence
// is moved past it afterwards.
func TestEnrichKeepsLegacyIDOnlyWhenFree(t *testing.T) {
	for name, sql := range map[string]string{"product": sqlEnrichInsertProductKeepID, "client": sqlEnrichInsertClientKeepID} {
		if !strings.Contains(sql, "WHERE NOT EXISTS") || !strings.Contains(sql, "ON CONFLICT DO NOTHING") {
			t.Errorf("%s keep-id insert is not guarded: %s", name, sql)
		}
	}
	for name, sql := range map[string]string{"product": sqlEnrichBumpProductSeq, "client": sqlEnrichBumpClientSeq} {
		if !strings.Contains(sql, "setval") || !strings.Contains(sql, "WHERE $1 >") {
			t.Errorf("%s sequence bump must only move forward: %s", name, sql)
		}
	}
}

// The legacy read is SELECT-only and scoped to the source enterprise.
func TestEnrichLegacyReadIsScopedSelect(t *testing.T) {
	s := strings.TrimSpace(sqlEnrichLegacyLinks)
	if !strings.HasPrefix(s, "SELECT") {
		t.Fatalf("legacy query must be a SELECT: %s", s)
	}
	if !strings.Contains(s, "po.id_enterprise = $1") || !strings.Contains(s, "po.id_order = ANY($2::bigint[])") {
		t.Errorf("legacy query not scoped to enterprise + candidate orders: %s", s)
	}
}

func TestBuildEnrichBatchDropsEmptyRows(t *testing.T) {
	orders, products, clients := buildEnrichBatch([]enrichRow{
		{idOrder: 1, productID: i64(10), clientID: i64(20)},
		{idOrder: 2}, // nothing resolved → no row
		{idOrder: 3, clientID: i64(21)},
	})
	if len(orders) != 2 || orders[0] != 1 || orders[1] != 3 {
		t.Fatalf("orders = %v, want [1 3]", orders)
	}
	if products[1] != nil || *clients[1] != 21 {
		t.Errorf("row 3: product should be NULL and client 21, got %v / %v", products[1], clients[1])
	}
	if len(products) != len(orders) || len(clients) != len(orders) {
		t.Errorf("arrays must stay parallel: %d/%d/%d", len(orders), len(products), len(clients))
	}
}
