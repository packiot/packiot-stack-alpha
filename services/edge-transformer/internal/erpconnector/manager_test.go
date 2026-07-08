package erpconnector

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

func TestNewRefusesNonSecretDSN(t *testing.T) {
	// The core secrets-by-ref enforcement: a literal DSN in a database
	// integration fails at New, before any connection is attempted.
	_, err := New(Config{
		Integrations: []clientconfig.Integration{{
			Type:   "database",
			Driver: "sqlite",
			DSNRef: "user=scott;password=tiger;host=erp.local", // literal, not secret://
		}},
		Resolver:  StaticResolver{},
		Templates: NewTemplateStore(t.TempDir()),
	})
	if err == nil {
		t.Fatal("New with literal DSN: want error, got nil")
	}
	if !strings.Contains(err.Error(), SecretScheme) {
		t.Fatalf("error should mention the required scheme, got: %v", err)
	}
}

func TestNewRejectsUnknownDriver(t *testing.T) {
	// oracle is the production target but is NOT registered in DefaultDrivers
	// (its client is not vendored). A descriptor asking for it must fail loud.
	_, err := New(Config{
		Integrations: []clientconfig.Integration{{
			Type:   "database",
			Driver: "oracle",
			DSNRef: "secret://incoplast/erp/dsn",
		}},
		Resolver:  StaticResolver{},
		Templates: NewTemplateStore(t.TempDir()),
	})
	if err == nil || !strings.Contains(err.Error(), "no driver registered") {
		t.Fatalf("want unknown-driver error, got: %v", err)
	}
}

func TestManagerInertWhenNoDatabaseIntegration(t *testing.T) {
	// No integrations, and an operator/commands capability that is NOT a
	// database integration — the connector must be a no-op.
	m, err := New(Config{
		Integrations: []clientconfig.Integration{
			{Type: "rest", Driver: "http"}, // ignored — not "database"
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if m.Enabled() {
		t.Fatal("Enabled() = true with no database integration")
	}
	// Start returns immediately (no-op). If it blocked, the test would hang.
	if err := m.Start(context.Background()); err != nil {
		t.Fatalf("inert Start returned error: %v", err)
	}
}

func TestManagerNoIntegrationsAtAll(t *testing.T) {
	m, err := New(Config{})
	if err != nil {
		t.Fatalf("New with empty config: %v", err)
	}
	if m.Enabled() {
		t.Fatal("Enabled() true with zero integrations")
	}
	if err := m.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
}

func TestManagerReadCycleFeedsSink(t *testing.T) {
	// End-to-end through the reference driver: New → open → runReadCycle →
	// ReadSink receives mapped rows. Proves the read seam.
	dbPath := filepath.Join(t.TempDir(), "erp.db")
	seed := newSQLiteConnAt(t, dbPath,
		`CREATE TABLE production_orders (id INTEGER, code TEXT)`,
		`INSERT INTO production_orders (id, code) VALUES (7,'PO-7')`,
	)
	_ = seed.Close() // reopened by the connector via the resolver

	root := templateDir(t, map[string]string{
		"read_pos.sql": "SELECT id, code FROM production_orders ORDER BY id",
	})

	var got []ReadResult
	m, err := New(Config{
		Integrations: []clientconfig.Integration{{
			Type:   "database",
			Driver: "sqlite",
			DSNRef: "secret://tenant/erp/dsn",
			Reads:  []string{"read_pos.sql"},
		}},
		Resolver:  StaticResolver{"secret://tenant/erp/dsn": dbPath},
		Templates: NewTemplateStore(root),
		ReadSink:  func(_ context.Context, r ReadResult) error { got = append(got, r); return nil },
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if !m.Enabled() {
		t.Fatal("Enabled() = false with a database integration")
	}
	if err := m.open(context.Background()); err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(m.closeAll)

	if err := m.runReadCycle(context.Background()); err != nil {
		t.Fatalf("runReadCycle: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("sink got %d results, want 1", len(got))
	}
	if len(got[0].Rows) != 1 || got[0].Rows[0]["code"] != "PO-7" {
		t.Fatalf("unexpected rows: %+v", got[0].Rows)
	}
}

func TestManagerOpenRefusesLiteralAtResolveTime(t *testing.T) {
	// Belt-and-suspenders: even a Manager whose specs somehow carried a
	// literal DSN is caught at open(), not connected. Build the spec directly
	// to bypass New's check and prove the second gate holds.
	m := &Manager{
		specs: []databaseSpec{{
			integration: clientconfig.Integration{
				Type: "database", Driver: "sqlite", DSNRef: "literal-dsn",
			},
			driver: SQLiteDriver{},
		}},
		resolver:  StaticResolver{},
		templates: NewTemplateStore(t.TempDir()),
	}
	if err := m.open(context.Background()); err == nil {
		t.Fatal("open() with literal DSN: want error, got nil")
	}
}

// newSQLiteConnAt is newSQLiteConn against a caller-chosen path (so a test
// can seed a DB the Manager will later reopen through its resolver).
func newSQLiteConnAt(t *testing.T, path string, setup ...string) Conn {
	t.Helper()
	conn, err := SQLiteDriver{}.Open(context.Background(), path)
	if err != nil {
		t.Fatalf("open sqlite at %s: %v", path, err)
	}
	for _, stmt := range setup {
		if _, err := conn.Exec(context.Background(), stmt); err != nil {
			t.Fatalf("setup %q: %v", stmt, err)
		}
	}
	return conn
}
