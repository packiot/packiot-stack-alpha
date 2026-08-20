package tenants

import (
	"reflect"
	"testing"
)

func TestFilterAllowlist(t *testing.T) {
	tests := []struct {
		name       string
		discovered []string
		allow      []string
		want       []string
	}{
		{
			name:       "empty allowlist is passthrough (prod default)",
			discovered: []string{"cpack", "incoplast", "neopac"},
			allow:      nil,
			want:       []string{"cpack", "incoplast", "neopac"},
		},
		{
			name:       "empty (zero-len) allowlist is passthrough",
			discovered: []string{"cpack", "incoplast"},
			allow:      []string{},
			want:       []string{"cpack", "incoplast"},
		},
		{
			name:       "allowlist scopes to its members, preserving discovered order",
			discovered: []string{"neopac", "cpack", "incoplast", "sbxcpack"},
			allow:      []string{"cpack", "sbxcpack"},
			want:       []string{"cpack", "sbxcpack"},
		},
		{
			name:       "case-insensitive on both sides",
			discovered: []string{"CPACK", "Incoplast", "SbxCpack"},
			allow:      []string{"cpack", "sbxcpack"},
			want:       []string{"CPACK", "SbxCpack"},
		},
		{
			name:       "unknown allowlist entries are silently absent, not errors",
			discovered: []string{"cpack"},
			allow:      []string{"cpack", "sbxcpack", "ghost"},
			want:       []string{"cpack"},
		},
		{
			name:       "no overlap yields empty result",
			discovered: []string{"neopac", "incoplast"},
			allow:      []string{"cpack"},
			want:       nil,
		},
		{
			name:       "empty discovered stays empty under any allowlist",
			discovered: nil,
			allow:      []string{"cpack"},
			want:       nil,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := FilterAllowlist(tc.discovered, tc.allow)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("FilterAllowlist(%v, %v) = %v; want %v",
					tc.discovered, tc.allow, got, tc.want)
			}
		})
	}
}
