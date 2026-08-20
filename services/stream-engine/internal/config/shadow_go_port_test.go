package config

import (
	"os"
	"testing"
)

// TestShadowGoPortEnabledDefault verifies the ADR-0045 G3 flag: it defaults
// to TRUE (staging back-compat) and only goes false when explicitly set.
func TestShadowGoPortEnabledDefault(t *testing.T) {
	cases := []struct {
		name  string
		set   bool
		value string
		want  bool
	}{
		{name: "unset → default true", set: false, want: true},
		{name: "explicit true", set: true, value: "true", want: true},
		{name: "explicit false", set: true, value: "false", want: false},
		{name: "garbage → not 'true' → false", set: true, value: "yes", want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			os.Unsetenv("SHADOW_GO_PORT_ENABLED")
			if tc.set {
				os.Setenv("SHADOW_GO_PORT_ENABLED", tc.value)
				defer os.Unsetenv("SHADOW_GO_PORT_ENABLED")
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if cfg.ShadowGoPortEnabled != tc.want {
				t.Fatalf("ShadowGoPortEnabled = %v, want %v", cfg.ShadowGoPortEnabled, tc.want)
			}
		})
	}
}
