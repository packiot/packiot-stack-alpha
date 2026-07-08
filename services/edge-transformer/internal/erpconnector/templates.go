package erpconnector

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// TemplateStore loads versioned SQL template files from a single root
// directory (the tenant's `sql/` dir, checked into the tenant repo and
// reviewed like code). It is the reason SQL is never built from runtime
// data: a read/write reference is a FILE PATH resolved here, and the file's
// contents are handed to Conn.Query/Exec verbatim, with runtime values
// supplied as bound parameters — not concatenated in.
//
// The store refuses any reference that escapes its root (absolute paths,
// `..` traversal). A descriptor cannot point the connector at
// /etc/passwd or a file outside the reviewed tenant SQL directory.
type TemplateStore struct {
	root string

	mu    sync.RWMutex
	cache map[string]string
}

// NewTemplateStore roots a store at dir (e.g. /etc/packiot/tenant/incoplast).
// A read ref "sql/read_pos.sql" then resolves to dir/sql/read_pos.sql.
func NewTemplateStore(dir string) *TemplateStore {
	return &TemplateStore{
		root:  dir,
		cache: make(map[string]string),
	}
}

// Load returns the SQL text for ref, reading from disk once and caching
// thereafter (templates are versioned files, immutable within a deploy).
// It returns an error for an empty ref, a path that escapes the root, or a
// missing file — all init-time misconfigurations that should fail loud.
func (t *TemplateStore) Load(ref string) (string, error) {
	if strings.TrimSpace(ref) == "" {
		return "", fmt.Errorf("erpconnector: empty sql template reference")
	}

	t.mu.RLock()
	if sql, ok := t.cache[ref]; ok {
		t.mu.RUnlock()
		return sql, nil
	}
	t.mu.RUnlock()

	full, err := t.resolve(ref)
	if err != nil {
		return "", err
	}
	raw, err := os.ReadFile(full)
	if err != nil {
		return "", fmt.Errorf("erpconnector: read sql template %q: %w", ref, err)
	}
	sql := string(raw)

	t.mu.Lock()
	t.cache[ref] = sql
	t.mu.Unlock()
	return sql, nil
}

// resolve joins ref onto root and verifies the result stays inside root.
// The Rel check is the traversal guard: any ref that climbs out produces a
// relative path beginning with ".." and is rejected.
func (t *TemplateStore) resolve(ref string) (string, error) {
	clean := filepath.Clean(ref)
	if filepath.IsAbs(clean) {
		return "", fmt.Errorf("erpconnector: sql template %q must be a relative path", ref)
	}
	full := filepath.Join(t.root, clean)
	rel, err := filepath.Rel(t.root, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("erpconnector: sql template %q escapes template root", ref)
	}
	return full, nil
}
