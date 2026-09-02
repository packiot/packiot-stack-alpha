package main

import "testing"

// TestAnalyticsRoutingKey pins the fix2 per-tenant routing flip:
//   - default (flag off) → the 2-segment legacy firehose key, so the exact-
//     bound stream-engine-q keeps consuming (byte-identical to pre-fix2).
//   - flag on → sparkplug.data.<tenant>, so the topic exchange shards each
//     tenant into its own stream-engine-q-<tenant>.
//   - empty tenant is a safety fallback: never emit a dangling
//     "sparkplug.data." key that would match no per-tenant binding.
func TestAnalyticsRoutingKey(t *testing.T) {
	cases := []struct {
		name      string
		perTenant bool
		tenant    string
		want      string
	}{
		{"default off is legacy firehose key", false, "cpack", "sparkplug.data"},
		{"off ignores tenant", false, "sbxcpack", "sparkplug.data"},
		{"on shards cpack", true, "cpack", "sparkplug.data.cpack"},
		{"on shards sbxcpack", true, "sbxcpack", "sparkplug.data.sbxcpack"},
		{"on with empty tenant falls back to legacy key", true, "", "sparkplug.data"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := analyticsRoutingKey(tc.perTenant, tc.tenant); got != tc.want {
				t.Fatalf("analyticsRoutingKey(%v, %q) = %q; want %q",
					tc.perTenant, tc.tenant, got, tc.want)
			}
		})
	}
}
