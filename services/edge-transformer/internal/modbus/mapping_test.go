package modbus

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

func sampleCfg() *clientconfig.Config {
	unit := 1
	return &clientconfig.Config{
		TenantID: "cpack",
		PLC: &clientconfig.PLC{
			Protocol: "modbus",
			Endpoints: []clientconfig.PLCEndpoint{
				{Name: "MACH_1", HostRef: "secret://cpack/plc/mach1", UnitID: &unit},
				{Name: "OTHER", HostRef: "secret://cpack/plc/other"},
			},
		},
		ModbusTagMap: []clientconfig.ModbusEndpointTags{
			{
				Endpoint:    "MACH_1",
				PackMLTopic: "CPACK/PLANT/LINE1/MACH_1/MACH_1",
				IDEquipment: 880001,
				Tags: []clientconfig.ModbusTag{
					{Metric: "/Admin/ProdProcessedCount/1/Unit", Kind: "holding", Address: 0, Type: "uint32"},
					{Metric: "/Status/MachSpeed", Kind: "input", Address: 10, Type: "float32", Scale: 0.1, WordSwap: true},
					{Metric: "/Status/StateCurrent", Kind: "holding", Address: 4, Type: "int16", Long: true},
					{Metric: "/Status/Running", Kind: "coil", Address: 0},
				},
			},
			{ // a second endpoint's tags — must NOT leak into MACH_1's set
				Endpoint:    "OTHER",
				PackMLTopic: "CPACK/PLANT/LINE1/OTHER/OTHER",
				IDEquipment: 880099,
				Tags:        []clientconfig.ModbusTag{{Metric: "/Status/MachSpeed", Kind: "holding", Address: 0, Type: "uint16"}},
			},
		},
	}
}

func TestFindEndpoint(t *testing.T) {
	cfg := sampleCfg()
	ep, ok := FindEndpoint(cfg, "MACH_1")
	if !ok || ep.UnitID == nil || *ep.UnitID != 1 {
		t.Fatalf("FindEndpoint MACH_1 = %+v ok=%v", ep, ok)
	}
	if _, ok := FindEndpoint(cfg, "NOPE"); ok {
		t.Fatal("FindEndpoint NOPE should be !ok")
	}
}

func TestTagsForEndpoint(t *testing.T) {
	cfg := sampleCfg()
	tags, err := TagsForEndpoint(cfg, "MACH_1")
	if err != nil {
		t.Fatalf("TagsForEndpoint: %v", err)
	}
	if len(tags) != 4 {
		t.Fatalf("want 4 tags for MACH_1 (OTHER excluded), got %d", len(tags))
	}
	if tags[0].Metric != "CPACK/PLANT/LINE1/MACH_1/MACH_1/Admin/ProdProcessedCount/1/Unit" {
		t.Fatalf("metric name = %q", tags[0].Metric)
	}
	if tags[0].Kind != KindHolding || tags[0].Type != TypeUint32 {
		t.Fatalf("tag0 kind/type = %v/%v", tags[0].Kind, tags[0].Type)
	}
	if tags[1].Kind != KindInput || tags[1].Type != TypeFloat32 || !tags[1].WordSwap || tags[1].Scale != 0.1 {
		t.Fatalf("tag1 = %+v", tags[1])
	}
	if !tags[2].Long {
		t.Fatal("StateCurrent should emit as Long")
	}
	// Coil tag: kind coil, type forced to bool even though the config had no type.
	if tags[3].Kind != KindCoil || tags[3].Type != TypeBool {
		t.Fatalf("coil tag = %+v want kind=coil type=bool", tags[3])
	}
	seen := map[uint64]bool{}
	for _, tg := range tags {
		if seen[tg.Alias] || tg.Alias == 0 {
			t.Fatalf("bad/duplicate alias %d", tg.Alias)
		}
		seen[tg.Alias] = true
	}

	if _, err := TagsForEndpoint(cfg, "NONEXISTENT"); err == nil {
		t.Fatal("TagsForEndpoint for unknown endpoint must error (zero tags)")
	}
}

func TestParseKindAndType(t *testing.T) {
	for tok, want := range map[string]Kind{"holding": KindHolding, "input": KindInput, "coil": KindCoil, "discrete": KindDiscrete} {
		if got, err := parseKind(tok); err != nil || got != want {
			t.Fatalf("parseKind(%q) = %v,%v want %v", tok, got, err, want)
		}
	}
	if _, err := parseKind("register"); err == nil {
		t.Fatal("parseKind(register) must error")
	}
	for tok, want := range map[string]Type{"uint16": TypeUint16, "int16": TypeInt16, "uint32": TypeUint32, "int32": TypeInt32, "float32": TypeFloat32, "bool": TypeBool} {
		if got, err := parseType(tok); err != nil || got != want {
			t.Fatalf("parseType(%q) = %v,%v want %v", tok, got, err, want)
		}
	}
	if _, err := parseType("real"); err == nil {
		t.Fatal("parseType(real) must error")
	}
}
