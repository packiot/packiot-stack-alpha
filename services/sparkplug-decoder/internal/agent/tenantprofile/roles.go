package tenantprofile

import "strings"

// ADR-0061 D2/D9 — the role catalogue. A metric's MEANING is declared (here,
// per metric template, and carried in the birth as properties.role), so cloud
// consumers dispatch on the role and never parse a leaf name. Roles are only
// for telemetry and commands; per-equipment configuration lives in columns.
//
// Keep in sync with docs/adr/0061-remove-packml-from-the-cloud.md §D9 and the
// stream-engine verifier's legacy-role table (internal/birthverify).
var roleCatalogue = map[string]bool{
	"counter.gross": true, "counter.net": true, "counter.scrap": true, "counter.custom": true,
	"state.current": true, "state.derived_running": true, "mode.current": true,
	"speed.current": true, "speed.nominal": true,
	"po.create": true, "po.start": true, "po.stop": true, "po.pause": true,
	"po.setup.begin": true, "po.setup.end": true,
	"event.justify": true, "event.manual.create": true, "event.manual.update": true,
	"event.trim.first": true, "event.trim.second": true,
	"counter.scrap.reset": true, "analog.values": true, "audit.user_log": true,
}

// ValidRole reports whether r is in the D9 catalogue.
func ValidRole(r string) bool { return roleCatalogue[r] }

// defaultRoleByLeaf is the ONBOARDING-TIME default for a template that declares
// no role: the one place a leaf name is mapped to meaning, applied when the
// agent config is generated — never by a cloud consumer at runtime. A template
// may always override it with an explicit role. Leaves absent here (e.g.
// Parameter30700 — configuration, dropped by D9) get no role.
var defaultRoleByLeaf = map[string]string{
	"ProdConsumedCount":  "counter.gross",
	"ProdProcessedCount": "counter.net",
	"ProdDefectiveCount": "counter.scrap",
	"StateCurrent":       "state.current",
	"UnitModeCurrent":    "mode.current",
	"CurMachSpeed":       "speed.current",
	"MachSpeed":          "speed.nominal",
}

// DefaultRole returns the onboarding default role for a template leaf such as
// "/Admin/ProdConsumedCount/{idx}/Unit" or "/Status/StateCurrent" ("" = none).
func DefaultRole(leaf string) string {
	for _, seg := range strings.Split(leaf, "/") {
		if r, ok := defaultRoleByLeaf[seg]; ok {
			return r
		}
	}
	return ""
}

// RoleOf is the role a template entry declares, else its leaf default.
func (t TemplateEntry) RoleOf() string {
	if r := strings.TrimSpace(t.Role); r != "" {
		return r
	}
	return DefaultRole(t.Leaf)
}
