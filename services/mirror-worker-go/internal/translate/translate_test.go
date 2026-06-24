// translate_test.go — unit tests for the pure helpers in Translator.
//
// The body of Translator.Site / Area / Equipment / ProductionOrder /
// EquipmentEvent runs SQL against live prod + staging pools — those
// integration-shaped tests would need a Postgres fixture and are out of
// scope here. What's testable in isolation:
//
//   - RemapTopic       — pure string substitution (exported for handler use)
//   - Translator.Enterprise — config-only, no DB
//
// If we ever add a fake *db.Prod / *db.Staging behind an interface (the
// translator currently takes concrete types so reach-through SQL works
// the same in prod + tests), the SQL-bound methods become testable too.
package translate

import (
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
)

func TestRemapTopicExported(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		// Real CPACK topic shapes — taken from packml_register dumps.
		{"prod prefix line", "C-PACK/SC/SLEEVE/SLEEVE1", "CPACK/SC/SLEEVE/SLEEVE1"},
		{"prod prefix unit", "C-PACK/SC/SLEEVE/SLEEVE1/SLEEVE1", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1"},
		// Idempotent: a topic that already uses the staging prefix passes through.
		{"already staging", "CPACK/SC/SLEEVE/SLEEVE1", "CPACK/SC/SLEEVE/SLEEVE1"},
		// Only the first occurrence is replaced — strings.Replace(...,1).
		// Real prod topics never contain a second 'C-PACK/' segment, but the
		// behaviour is worth pinning so a future regex change is intentional.
		{"first occurrence only", "C-PACK/X/C-PACK/Y", "CPACK/X/C-PACK/Y"},
		// Empty / no prefix — pass through unchanged.
		{"empty", "", ""},
		{"unrelated topic", "OTHER/SC/LINE", "OTHER/SC/LINE"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := RemapTopic(c.in)
			if got != c.want {
				t.Errorf("RemapTopic(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestEnterprise(t *testing.T) {
	cfg := &config.Config{
		ProdEnterpriseID:    1,
		StagingEnterpriseID: 3,
	}
	tr := &Translator{cfg: cfg, logger: slog.Default()}

	t.Run("happy path", func(t *testing.T) {
		got, err := tr.Enterprise(1)
		if err != nil {
			t.Fatalf("Enterprise(1) err = %v", err)
		}
		if got != 3 {
			t.Errorf("Enterprise(1) = %d, want 3", got)
		}
	})

	t.Run("rejects unexpected prod ID", func(t *testing.T) {
		// Defensive — the worker only ever replays one prod enterprise. If a
		// row comes in for a different enterprise (config drift or someone
		// adding a second tenant without the prep work), we want a loud
		// failure, not silent miss-routing.
		_, err := tr.Enterprise(99)
		if err == nil {
			t.Errorf("Enterprise(99) err = nil, want non-nil")
		}
	})
}

// TestProductionOrderQueryUsesIDOrder pins the column name in the
// ProductionOrder SQL. The original TS port referenced a fictional column
// `nu_production_order` that doesn't exist on prod (or staging) — the live
// /metrics DLQ surfaced ~120 SQLSTATE 42703 failures from this exact code
// path. The actual human PO number column is `id_order` (integer, unique
// per id_enterprise — see prod's `production_orders_un` constraint).
//
// We can't easily exercise the SQL at unit-test time (it needs a live pg
// pool), so we instead read the source file and assert the textual SQL
// uses the right column. Crude but effective — catches a regression at
// `go test` time with zero infra cost.
//
// We scan only the SQL string literals (text between back-ticks) so the
// fix's explanatory comments are free to reference the bug-string by
// name without tripping the guard.
func TestProductionOrderQueryUsesIDOrder(t *testing.T) {
	src, err := os.ReadFile("translate.go")
	if err != nil {
		t.Fatalf("read translate.go: %v", err)
	}
	body := string(src)

	// Carve out the SQL string literals — anything between back-ticks.
	// A regex would also work; manual scan keeps the dep surface tiny.
	var sqlOnly strings.Builder
	inBacktick := false
	for _, ch := range body {
		if ch == '`' {
			inBacktick = !inBacktick
			continue
		}
		if inBacktick {
			sqlOnly.WriteRune(ch)
		}
	}
	sqlBlob := sqlOnly.String()

	if strings.Contains(sqlBlob, "nu_production_order") {
		t.Errorf("translate.go SQL still references nu_production_order — prod uses id_order; the column nu_production_order does not exist (SQLSTATE 42703 in DLQ)")
	}
	// Positive guard — both the prod-side and staging-side queries must
	// filter on id_order.
	wantSubs := []string{
		"SELECT id_order FROM production_orders",
		"WHERE id_order = $1 AND id_enterprise = $2",
	}
	for _, s := range wantSubs {
		if !strings.Contains(sqlBlob, s) {
			t.Errorf("translate.go SQL missing expected substring %q after id_order fix", s)
		}
	}
}
