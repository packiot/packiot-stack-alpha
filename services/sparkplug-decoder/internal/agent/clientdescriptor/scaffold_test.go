package clientdescriptor

import (
	"strings"
	"testing"
)

// TestScaffold_RoundTrips is the core scaffold contract: whatever Scaffold emits
// must be a VALID descriptor — i.e. the commented YAML round-trips back through
// Parse (the same path onboard-gen and the onboard API run). A scaffold that does
// not parse would hand the CS engineer a broken starting point.
func TestScaffold_RoundTrips(t *testing.T) {
	opts := ScaffoldOptions{Tenant: "acme", Site: "sp", Lines: 2, Protocols: []string{"s7", "modbus"}}

	yamlBytes, err := ScaffoldYAML(opts)
	if err != nil {
		t.Fatalf("ScaffoldYAML: %v", err)
	}

	// The emitted document (header comments + spine + commented tag-map guide) must
	// parse + validate as-is.
	d, err := Parse(yamlBytes)
	if err != nil {
		t.Fatalf("scaffold output does not round-trip through Parse: %v\n%s", err, yamlBytes)
	}

	// Identity: uppercased tenant + <TENANT>/<SITE> prefix.
	if d.Tenant != "ACME" {
		t.Errorf("tenant: got %q want ACME", d.Tenant)
	}
	if d.Canonical.Prefix != "ACME/SP" {
		t.Errorf("prefix: got %q want ACME/SP", d.Canonical.Prefix)
	}

	// Two lines ⇒ two line equipments (tp=3) + two member machines (tp=1).
	var lines, members int
	for _, e := range d.Equipment {
		switch e.TPEquipment {
		case 3:
			lines++
		case 1:
			members++
		}
	}
	if lines != 2 || members != 2 {
		t.Errorf("equipment mix: got %d lines / %d members, want 2 / 2", lines, members)
	}

	// One endpoint per requested protocol; no ACTIVE tag maps (they are commented).
	if d.PLC == nil || len(d.PLC.Endpoints) != 2 {
		t.Fatalf("want 2 plc endpoints (s7 + modbus), got %+v", d.PLC)
	}
	if len(d.PLC.S7TagMap)+len(d.PLC.ModbusTagMap)+len(d.PLC.OPCUATagMap) != 0 {
		t.Errorf("scaffold must emit NO active tag maps, got s7=%d modbus=%d opcua=%d",
			len(d.PLC.S7TagMap), len(d.PLC.ModbusTagMap), len(d.PLC.OPCUATagMap))
	}
	gotProtos := map[string]bool{}
	for _, ep := range d.PLC.Endpoints {
		gotProtos[ep.Protocol] = true
		// Hosts/URLs are secret refs, never values.
		if ep.HostRef != "" && !strings.HasPrefix(ep.HostRef, "secret://") {
			t.Errorf("endpoint %s host_ref is not a secret ref: %q", ep.Name, ep.HostRef)
		}
		if ep.EndpointURLRef != "" && !strings.HasPrefix(ep.EndpointURLRef, "secret://") {
			t.Errorf("endpoint %s endpoint_url_ref is not a secret ref: %q", ep.Name, ep.EndpointURLRef)
		}
	}
	if !gotProtos[PLCProtocolS7] || !gotProtos[PLCProtocolModbusTCP] {
		t.Errorf("want s7 + modbus_tcp endpoints, got %v", gotProtos)
	}

	// A fresh client has captured nothing: every member index starts inferred, so
	// the cutover gate must refuse. This teaches the confirmed/inferred discipline.
	if got := d.InferredMembers(); len(got) != 2 {
		t.Errorf("want 2 inferred members on a fresh scaffold, got %v", got)
	}

	// The multi-protocol scaffold documents the multi-source pattern in its
	// commented guidance so the engineer sees how two PLCs feed one equipment.
	if !strings.Contains(string(yamlBytes), "MULTI-SOURCE") {
		t.Error("multi-protocol scaffold should document the multi-source pattern")
	}
	if !strings.Contains(string(yamlBytes), "s7_tag_map:") || !strings.Contains(string(yamlBytes), "modbus_tag_map:") {
		t.Error("scaffold guidance should show both an s7 and a modbus tag-map example")
	}
}

// TestScaffold_DefaultsAndValidation covers the input edges: protocol default,
// the modbus alias, and the required-field / range guards.
func TestScaffold_DefaultsAndValidation(t *testing.T) {
	// Default protocol is s7.
	d, err := Scaffold(ScaffoldOptions{Tenant: "acme", Site: "sp", Lines: 1})
	if err != nil {
		t.Fatalf("Scaffold default protocol: %v", err)
	}
	if len(d.PLC.Endpoints) != 1 || d.PLC.Endpoints[0].Protocol != PLCProtocolS7 {
		t.Errorf("default protocol should be a single s7 endpoint, got %+v", d.PLC.Endpoints)
	}

	// "modbus" is accepted as an alias for modbus_tcp.
	d2, err := Scaffold(ScaffoldOptions{Tenant: "acme", Site: "sp", Lines: 1, Protocols: []string{"modbus"}})
	if err != nil {
		t.Fatalf("Scaffold modbus alias: %v", err)
	}
	if d2.PLC.Endpoints[0].Protocol != PLCProtocolModbusTCP {
		t.Errorf("modbus alias should map to %q, got %q", PLCProtocolModbusTCP, d2.PLC.Endpoints[0].Protocol)
	}

	// Guards.
	cases := []struct {
		name string
		opts ScaffoldOptions
	}{
		{"no tenant", ScaffoldOptions{Site: "sp", Lines: 1}},
		{"no site", ScaffoldOptions{Tenant: "acme", Lines: 1}},
		{"zero lines", ScaffoldOptions{Tenant: "acme", Site: "sp", Lines: 0}},
		{"bad protocol", ScaffoldOptions{Tenant: "acme", Site: "sp", Lines: 1, Protocols: []string{"profibus"}}},
	}
	for _, c := range cases {
		if _, err := Scaffold(c.opts); err == nil {
			t.Errorf("%s: expected an error, got nil", c.name)
		}
	}
}
