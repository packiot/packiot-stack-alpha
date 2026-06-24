// translate_test.go — unit tests for the pure helpers in Translator.
//
// The body of Translator.Site / Area / Equipment / ProductionOrder /
// EquipmentEvent runs SQL against live prod + staging pools — those
// integration-shaped tests would need a Postgres fixture and are out of
// scope here. What's testable in isolation:
//
//   - remapTopic       — pure string substitution
//   - Translator.Enterprise — config-only, no DB
//
// If we ever add a fake *db.Prod / *db.Staging behind an interface (the
// translator currently takes concrete types so reach-through SQL works
// the same in prod + tests), the SQL-bound methods become testable too.
package translate

import (
	"log/slog"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
)

func TestRemapTopic(t *testing.T) {
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
			got := remapTopic(c.in)
			if got != c.want {
				t.Errorf("remapTopic(%q) = %q, want %q", c.in, got, c.want)
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
