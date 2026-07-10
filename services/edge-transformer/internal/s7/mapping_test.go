package s7

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

func sampleCfg() *clientconfig.Config {
	rack, slot := 0, 2
	return &clientconfig.Config{
		TenantID: "incoplast",
		PLC: &clientconfig.PLC{
			Protocol: "s7",
			Endpoints: []clientconfig.PLCEndpoint{
				{Name: "NOVOFLEX_15", HostRef: "secret://incoplast/plc/nf15", Rack: &rack, Slot: &slot},
				{Name: "OTHER", HostRef: "secret://incoplast/plc/other"},
			},
		},
		S7TagMap: []clientconfig.S7EndpointTags{
			{
				Endpoint:    "NOVOFLEX_15",
				PackMLTopic: "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15",
				IDEquipment: 990015,
				Tags: []clientconfig.S7Tag{
					{Metric: "/Admin/ProdProcessedCount/1/Unit", DB: 100, Offset: 0, Type: "dint"},
					{Metric: "/Status/MachSpeed", DB: 100, Offset: 8, Type: "real", Scale: 0.1},
					{Metric: "/Status/StateCurrent", DB: 100, Offset: 12, Type: "int", Long: true},
				},
			},
			{ // a second endpoint's tags — must NOT leak into NOVOFLEX_15's set
				Endpoint:    "OTHER",
				PackMLTopic: "INCOPLAST/SAO_LUDGERO/IMPRESSAO/OTHER/OTHER",
				IDEquipment: 990099,
				Tags:        []clientconfig.S7Tag{{Metric: "/Status/MachSpeed", DB: 5, Offset: 0, Type: "real"}},
			},
		},
	}
}

func TestFindEndpoint(t *testing.T) {
	cfg := sampleCfg()
	ep, ok := FindEndpoint(cfg, "NOVOFLEX_15")
	if !ok || ep.Rack == nil || *ep.Rack != 0 || ep.Slot == nil || *ep.Slot != 2 {
		t.Fatalf("FindEndpoint NOVOFLEX_15 = %+v ok=%v", ep, ok)
	}
	if _, ok := FindEndpoint(cfg, "NOPE"); ok {
		t.Fatal("FindEndpoint NOPE should be !ok")
	}
}

func TestTagsForEndpoint(t *testing.T) {
	cfg := sampleCfg()
	tags, err := TagsForEndpoint(cfg, "NOVOFLEX_15")
	if err != nil {
		t.Fatalf("TagsForEndpoint: %v", err)
	}
	if len(tags) != 3 {
		t.Fatalf("want 3 tags for NOVOFLEX_15 (OTHER excluded), got %d", len(tags))
	}
	// Full metric name = packml_topic + suffix; aliases 1..N unique.
	if tags[0].Metric != "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15/Admin/ProdProcessedCount/1/Unit" {
		t.Fatalf("metric name = %q", tags[0].Metric)
	}
	if tags[0].Type != TypeDInt || tags[1].Type != TypeReal || tags[2].Type != TypeInt {
		t.Fatalf("types = %v %v %v", tags[0].Type, tags[1].Type, tags[2].Type)
	}
	if !tags[2].Long {
		t.Fatal("StateCurrent should emit as Long")
	}
	if tags[1].Scale != 0.1 {
		t.Fatalf("scale = %v want 0.1", tags[1].Scale)
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
	for tok, want := range map[string]Type{"int": TypeInt, "dint": TypeDInt, "real": TypeReal, "bool": TypeBool} {
		if got, err := parseType(tok); err != nil || got != want {
			t.Fatalf("parseType(%q) = %v,%v want %v", tok, got, err, want)
		}
	}
	if _, err := parseType("word"); err == nil {
		t.Fatal("parseType(word) must error")
	}
}
