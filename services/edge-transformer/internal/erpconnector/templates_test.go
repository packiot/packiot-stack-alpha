package erpconnector

import (
	"os"
	"path/filepath"
	"testing"
)

// writeTemplate creates dir/name with body and returns the store root.
func templateDir(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range files {
		full := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestTemplateStoreLoad(t *testing.T) {
	root := templateDir(t, map[string]string{
		"sql/read_pos.sql": "SELECT id, code FROM production_orders",
	})
	ts := NewTemplateStore(root)

	got, err := ts.Load("sql/read_pos.sql")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got != "SELECT id, code FROM production_orders" {
		t.Fatalf("Load returned %q", got)
	}

	// Cached second read returns the same content.
	if again, err := ts.Load("sql/read_pos.sql"); err != nil || again != got {
		t.Fatalf("cached Load = %q, %v", again, err)
	}
}

func TestTemplateStoreRejectsEscapes(t *testing.T) {
	root := templateDir(t, map[string]string{"sql/ok.sql": "SELECT 1"})
	ts := NewTemplateStore(root)

	tests := []struct {
		name string
		ref  string
	}{
		{"empty", ""},
		{"parent traversal", "../secrets.env"},
		{"nested traversal", "sql/../../etc/passwd"},
		{"absolute path", "/etc/passwd"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := ts.Load(tt.ref); err == nil {
				t.Fatalf("Load(%q): want error, got nil", tt.ref)
			}
		})
	}
}

func TestTemplateStoreMissingFile(t *testing.T) {
	ts := NewTemplateStore(t.TempDir())
	if _, err := ts.Load("sql/nope.sql"); err == nil {
		t.Fatal("Load of missing template: want error, got nil")
	}
}
