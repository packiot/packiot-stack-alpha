package opcua

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
)

func sampleCfg() *clientconfig.Config {
	return &clientconfig.Config{
		TenantID: "cpack",
		PLC: &clientconfig.PLC{
			Protocol: "opcua",
			Endpoints: []clientconfig.PLCEndpoint{
				{Name: "MACH_1", EndpointURLRef: "secret://cpack/plc/mach1-url", SecurityPolicy: "None", SecurityMode: "None"},
				{Name: "OTHER", EndpointURLRef: "secret://cpack/plc/other-url"},
			},
		},
		OPCUATagMap: []clientconfig.OPCUAEndpointTags{
			{
				Endpoint:    "MACH_1",
				PackMLTopic: "CPACK/PLANT/LINE1/MACH_1/MACH_1",
				IDEquipment: 880001,
				Tags: []clientconfig.OPCUATag{
					{Metric: "/Admin/ProdProcessedCount/1/Unit", NodeID: "ns=2;s=Count", Type: "int"},
					{Metric: "/Status/MachSpeed", NodeID: "ns=2;s=Speed", Type: "float", Scale: 0.1},
					{Metric: "/Status/StateCurrent", NodeID: "ns=2;i=42", Type: "int", Long: true},
				},
			},
			{ // a second endpoint's tags — must NOT leak into MACH_1's set
				Endpoint:    "OTHER",
				PackMLTopic: "CPACK/PLANT/LINE1/OTHER/OTHER",
				IDEquipment: 880099,
				Tags:        []clientconfig.OPCUATag{{Metric: "/Status/MachSpeed", NodeID: "ns=2;s=Speed", Type: "float"}},
			},
		},
	}
}

func TestFindEndpoint(t *testing.T) {
	cfg := sampleCfg()
	ep, ok := FindEndpoint(cfg, "MACH_1")
	if !ok || ep.EndpointURLRef != "secret://cpack/plc/mach1-url" {
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
	if len(tags) != 3 {
		t.Fatalf("want 3 tags for MACH_1 (OTHER excluded), got %d", len(tags))
	}
	if tags[0].Metric != "CPACK/PLANT/LINE1/MACH_1/MACH_1/Admin/ProdProcessedCount/1/Unit" {
		t.Fatalf("metric name = %q", tags[0].Metric)
	}
	if tags[0].NodeID != "ns=2;s=Count" || tags[0].Type != TypeInt {
		t.Fatalf("tag0 = %+v", tags[0])
	}
	if tags[1].Type != TypeFloat || tags[1].Scale != 0.1 {
		t.Fatalf("tag1 = %+v", tags[1])
	}
	if !tags[2].Long {
		t.Fatal("StateCurrent should emit as Long")
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

func TestParseType(t *testing.T) {
	for tok, want := range map[string]Type{"int": TypeInt, "float": TypeFloat, "bool": TypeBool, "string": TypeString} {
		if got, err := parseType(tok); err != nil || got != want {
			t.Fatalf("parseType(%q) = %v,%v want %v", tok, got, err, want)
		}
	}
	if _, err := parseType("double"); err == nil {
		t.Fatal("parseType(double) must error")
	}
}
