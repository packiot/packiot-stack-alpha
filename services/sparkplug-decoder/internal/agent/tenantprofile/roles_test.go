package tenantprofile

import (
	"strings"
	"testing"
)

func TestDefaultRoleAndOverride(t *testing.T) {
	for leaf, want := range map[string]string{
		"/Admin/ProdConsumedCount/{idx}/Unit":  "counter.gross",
		"/Admin/ProdProcessedCount":            "counter.net",
		"/Admin/ProdDefectiveCount/{idx}/Unit": "counter.scrap",
		"/Status/StateCurrent":                 "state.current",
		"/Status/UnitModeCurrent":              "mode.current",
		"/Status/CurMachSpeed":                 "speed.current",
		"/Status/MachSpeed":                    "speed.nominal",
		"/Status/Parameter30700":               "", // configuration, dropped by D9
	} {
		if got := DefaultRole(leaf); got != want {
			t.Errorf("DefaultRole(%q) = %q, want %q", leaf, got, want)
		}
		if want != "" && !ValidRole(want) {
			t.Errorf("default %q is not in the catalogue", want)
		}
	}
	// a declared role wins over the leaf default (CPACK's MachSpeed carries the CURRENT speed)
	if got := (TemplateEntry{Leaf: "/Status/MachSpeed", Role: "speed.current"}).RoleOf(); got != "speed.current" {
		t.Errorf("declared role = %q, want speed.current", got)
	}
}

func TestValidate_RejectsUnknownRole(t *testing.T) {
	p := &Profile{TenantPrefix: "X/Y", MetricTemplates: MetricTemplates{
		Line: []TemplateEntry{{Leaf: "/Status/StateCurrent", Type: "long", Role: "state.bogus"}},
	}}
	if err := p.Validate(); err == nil || !strings.Contains(err.Error(), "D9 catalogue") {
		t.Fatalf("want a catalogue error, got %v", err)
	}
	p.MetricTemplates.Line[0].Role = "state.current"
	if err := p.Validate(); err != nil {
		t.Fatalf("valid role rejected: %v", err)
	}
}
