// order_created_column_test.go — regression guard for DLQ id 284
// (source_log_id 2503473): SQLSTATE 42703 because the prod PO lookup
// queried `created_at`, which exists on staging but NOT on prod's
// production_orders table. The correct column on prod is ts_creation.
//
// Same flavour as translate_test.go's nu_production_order guard (PR #57).
// A static-string test is sufficient: any future edit reintroducing
// `created_at` to a prod query in either of these two handlers fails
// CI before it can ship.
package replay

import (
	"os"
	"strings"
	"testing"
)

func TestOrderCreatedHandlers_NoCreatedAtColumnReference(t *testing.T) {
	files := []string{"order_created.go", "order_created_started.go"}
	for _, f := range files {
		t.Run(f, func(t *testing.T) {
			src, err := os.ReadFile(f)
			if err != nil {
				t.Fatalf("read %s: %v", f, err)
			}
			// Grep only the SQL block — comments may legitimately mention
			// "created_at" when explaining the bug.
			body := string(src)
			sqlStart := strings.Index(body, "SELECT id_production_order::text FROM production_orders")
			if sqlStart == -1 {
				t.Fatalf("%s: prod PO lookup SQL no longer matches expected anchor", f)
			}
			sqlEnd := strings.Index(body[sqlStart:], "LIMIT 1`")
			if sqlEnd == -1 {
				t.Fatalf("%s: prod PO lookup SQL has no LIMIT 1 terminator", f)
			}
			sql := body[sqlStart : sqlStart+sqlEnd]
			if strings.Contains(sql, "created_at") {
				t.Errorf("%s: prod PO lookup references created_at — prod uses ts_creation (SQLSTATE 42703 in DLQ id 284)", f)
			}
			if !strings.Contains(sql, "ts_creation") {
				t.Errorf("%s: prod PO lookup is missing the ts_creation predicate", f)
			}
		})
	}
}
