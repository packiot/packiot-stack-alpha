package tenants

import "strings"

// FilterAllowlist intersects the DB-discovered tenant set with a static
// allowlist, so an environment declares/consumes ONLY the tenants it owns
// regardless of what foreign rows a shared/re-cut packml_register contains.
//
// Semantics:
//
//   - allow EMPTY (nil or len 0) → passthrough: return discovered unchanged.
//     This is the production default — no scoping, no behavior change.
//   - allow NON-EMPTY → return the members of discovered that are also in
//     allow, preserving discovered's order.
//
// The match is case-insensitive: both sides are lowercased before compare
// (DiscoverActive already lowercases group_ids; config.csvLower lowercases
// allowlist entries — this guards callers that build either side by hand).
//
// Allowlist entries that match no discovered tenant are simply absent from
// the result — an unknown/typo'd entry is a silent no-op, never an error.
// That keeps a staging allowlist stable across re-cuts even when a listed
// tenant is temporarily not onboarded.
func FilterAllowlist(discovered, allow []string) []string {
	if len(allow) == 0 {
		return discovered
	}
	allowed := make(map[string]struct{}, len(allow))
	for _, a := range allow {
		allowed[strings.ToLower(strings.TrimSpace(a))] = struct{}{}
	}
	var out []string
	for _, d := range discovered {
		if _, ok := allowed[strings.ToLower(strings.TrimSpace(d))]; ok {
			out = append(out, d)
		}
	}
	return out
}
