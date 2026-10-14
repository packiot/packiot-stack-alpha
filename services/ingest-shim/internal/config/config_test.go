package config

import (
	"strings"
	"testing"
)

// SCOPE_GROUP has no default: unset, empty (what compose.production.yml's
// `${INGEST_SCOPE_GROUP:-}` yields when the deployer forgets it) and
// whitespace-only must all refuse to start instead of falling back to
// another client's group.
func TestLoad_ScopeGroupRequired(t *testing.T) {
	cases := []struct {
		name  string
		set   bool
		value string
	}{
		{"unset", false, ""},
		{"empty", true, ""},
		{"blank", true, "   "},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("INGEST_API_KEY", "k")
			if tc.set {
				t.Setenv("SCOPE_GROUP", tc.value)
			} else {
				t.Setenv("SCOPE_GROUP", "")
			}
			c, err := Load()
			if err == nil {
				t.Fatalf("Load() = %+v, want error (no silent SCOPE_GROUP default)", c.ScopeGroup)
			}
			if !strings.Contains(err.Error(), "SCOPE_GROUP") {
				t.Fatalf("error %q does not name SCOPE_GROUP", err)
			}
		})
	}
}

func TestLoad_ScopeGroupExplicit(t *testing.T) {
	t.Setenv("INGEST_API_KEY", "k")
	t.Setenv("SCOPE_GROUP", " BISPHARMA ")
	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.ScopeGroup != "BISPHARMA" {
		t.Fatalf("ScopeGroup = %q, want BISPHARMA", c.ScopeGroup)
	}
}

// The Docker healthcheck exec has no SCOPE_GROUP plumbed in; it must still load.
func TestLoadForHealthcheck_NoScopeGroup(t *testing.T) {
	t.Setenv("SCOPE_GROUP", "")
	if _, err := LoadForHealthcheck(); err != nil {
		t.Fatalf("LoadForHealthcheck: %v", err)
	}
}
