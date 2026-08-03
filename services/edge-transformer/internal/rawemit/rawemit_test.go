package rawemit

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/modbus"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/s7"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// mixedCfg is a CPACK-shaped client.yaml with TWO endpoints of DIFFERENT
// protocols (one S7 cell + one Modbus packer) under a shared canonical prefix —
// the multi-PLC, mixed-protocol case the single-endpoint reader could not deploy.
func mixedCfg() *clientconfig.Config {
	rack, slot, unit := 0, 2, 1
	return &clientconfig.Config{
		SchemaVersion:   "1.1",
		TenantID:        "cpack",
		Customer:        "CPACK",
		Environment:     "staging",
		CanonicalPrefix: "CPACK/SC",
		PLC: &clientconfig.PLC{
			Endpoints: []clientconfig.PLCEndpoint{
				{Name: "CELULA1", HostRef: "secret://cpack/plc/celula1", Rack: &rack, Slot: &slot},
				{Name: "CELULA2", HostRef: "secret://cpack/plc/celula2", UnitID: &unit},
			},
		},
		S7TagMap: []clientconfig.S7EndpointTags{{
			Endpoint:    "CELULA1",
			PackMLTopic: "CPACK/SC/CELULA1/CER400",
			IDEquipment: 83,
			Tags: []clientconfig.S7Tag{
				{Metric: "/Admin/ProdProcessedCount/1/Unit", DB: 100, Offset: 0, Type: "dint"},
				{Metric: "/Status/MachSpeed", DB: 100, Offset: 8, Type: "real"},
			},
		}},
		ModbusTagMap: []clientconfig.ModbusEndpointTags{{
			Endpoint:    "CELULA2",
			PackMLTopic: "CPACK/SC/CELULA2/PACKER",
			IDEquipment: 84,
			Tags: []clientconfig.ModbusTag{
				{Metric: "/Admin/ProdProcessedCount/1/Unit", Kind: "holding", Address: 0, Type: "uint32"},
			},
		}},
	}
}

// TestMixedProtocolMetricSuffix proves that a 2-endpoint, mixed-protocol
// client.yaml yields BOTH endpoints' tags, each emitted with the group-relative
// metric_suffix (canonical_prefix stripped — the ADR-0045 §C key the agent
// resolves by). This is the load-bearing multi-endpoint contract: the s7-reader
// picks up CELULA1, the modbus-reader picks up CELULA2, and neither leaks the
// other's endpoint.
func TestMixedProtocolMetricSuffix(t *testing.T) {
	cfg := mixedCfg()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("mixed config must validate: %v", err)
	}

	// Each protocol reader enumerates ONLY its own protocol's endpoints.
	if got := s7.Endpoints(cfg); len(got) != 1 || got[0] != "CELULA1" {
		t.Fatalf("s7.Endpoints = %v, want [CELULA1]", got)
	}
	if got := modbus.Endpoints(cfg); len(got) != 1 || got[0] != "CELULA2" {
		t.Fatalf("modbus.Endpoints = %v, want [CELULA2]", got)
	}

	// S7 endpoint: compile tags → simulate a poller sample (Name = full metric) →
	// strip canonical prefix. Assert the group-relative suffix.
	s7Tags, err := s7.TagsForEndpoint(cfg, "CELULA1")
	if err != nil {
		t.Fatalf("s7.TagsForEndpoint: %v", err)
	}
	s7Out := toOutTags(cfg.CanonicalPrefix, sampleFromTagNames(metricNamesS7(s7Tags)))
	wantS7 := []string{
		"/CELULA1/CER400/Admin/ProdProcessedCount/1/Unit",
		"/CELULA1/CER400/Status/MachSpeed",
	}
	assertMetrics(t, "s7", s7Out, wantS7)

	// Modbus endpoint: same contract, different protocol, same reader-agnostic strip.
	mbTags, err := modbus.TagsForEndpoint(cfg, "CELULA2")
	if err != nil {
		t.Fatalf("modbus.TagsForEndpoint: %v", err)
	}
	mbOut := toOutTags(cfg.CanonicalPrefix, sampleFromTagNames(metricNamesModbus(mbTags)))
	wantMB := []string{"/CELULA2/PACKER/Admin/ProdProcessedCount/1/Unit"}
	assertMetrics(t, "modbus", mbOut, wantMB)
}

// TestHostForEndpoint covers the per-endpoint host override (multi-PLC) and the
// protocol-wide fallback (single-endpoint back-compat), including name → env-var
// sanitization.
func TestHostForEndpoint(t *testing.T) {
	// No override set → fallback wins.
	if got := HostForEndpoint("CELULA1", "10.0.0.9:102"); got != "10.0.0.9:102" {
		t.Fatalf("fallback host = %q, want 10.0.0.9:102", got)
	}
	// Per-endpoint override wins over fallback; name is upper/sanitized.
	t.Setenv("PLC_HOST_CELL_1", "10.0.0.10:102")
	if got := HostForEndpoint("cell-1", "fallback"); got != "10.0.0.10:102" {
		t.Fatalf("override host = %q, want 10.0.0.10:102 (PLC_HOST_CELL_1)", got)
	}
	// Unset override, empty fallback → empty (caller skips the endpoint).
	if got := HostForEndpoint("CELULA2", ""); got != "" {
		t.Fatalf("no host = %q, want empty", got)
	}
}

// sampleFromTagNames fakes a poller sample: one SimMetric per tag, Name set to the
// full metric name (exactly what poller.Sample emits) so toOutTags exercises the
// real strip.
func sampleFromTagNames(names []string) []sparkplug.SimMetric {
	ms := make([]sparkplug.SimMetric, len(names))
	for i, n := range names {
		ms[i] = sparkplug.SimMetric{Name: n, Double: 1}
	}
	return ms
}

func metricNamesS7(tags []s7.Tag) []string {
	out := make([]string, len(tags))
	for i, t := range tags {
		out[i] = t.Metric
	}
	return out
}

func metricNamesModbus(tags []modbus.Tag) []string {
	out := make([]string, len(tags))
	for i, t := range tags {
		out[i] = t.Metric
	}
	return out
}

func assertMetrics(t *testing.T, label string, got []rawtag.OutTag, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: %d out tags, want %d", label, len(got), len(want))
	}
	for i, w := range want {
		if got[i].Metric != w {
			t.Fatalf("%s out[%d].Metric = %q, want %q", label, i, got[i].Metric, w)
		}
	}
}
