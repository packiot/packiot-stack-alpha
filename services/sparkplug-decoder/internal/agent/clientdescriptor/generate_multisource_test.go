package clientdescriptor

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
)

// multiSourceDescriptorPath locates the shipped multi-source example relative to
// THIS test source file (runtime.Caller), so the test proves the exact artifact
// under docs/clients/examples/ — not an inline copy that could silently drift
// from what a CS engineer reads. Walking up from the package dir to the repo root
// is deterministic regardless of the go-test working directory.
func multiSourceDescriptorPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	// thisFile = <repo>/services/edge-transformer/internal/agent/clientdescriptor/generate_multisource_test.go
	// docs/clients lives at the repo root, five directories up from the package.
	pkgDir := filepath.Dir(thisFile)
	return filepath.Join(pkgDir, "..", "..", "..", "..", "..",
		"docs", "clients", "examples", "multisource.descriptor.yaml")
}

// TestMultiSource_TwoProtocolsOneEquipment is the composition proof: a single
// equipment (ACME/SP/LINE1/FILLER, id 4201) whose canonical message is built from
// TWO source PLCs of DIFFERENT protocols — an S7 count + a Modbus speed. It runs
// the shipped example descriptor through the SAME generation path onboard-gen
// uses (Parse → GenerateClientYAML + GenerateAgentConfig) and asserts:
//
//	(1) the emitted client.yaml has BOTH endpoints, and both tag maps point at the
//	    SAME id_equipment / packml_topic (the "two PLCs, one message" shape);
//	(2) checkClientAgentConsistency PASSES — every reader metric resolves to a
//	    synthesized agent raw_tag_map suffix, so the agent will assemble both
//	    sources into the one equipment's message instead of dropping either;
//	(3) the two metric_suffixes are DISTINCT and BOTH present.
func TestMultiSource_TwoProtocolsOneEquipment(t *testing.T) {
	d, err := Load(multiSourceDescriptorPath(t))
	if err != nil {
		t.Fatalf("load multi-source example (Load runs full Validate incl. §C): %v", err)
	}

	// --- (1) client.yaml: two endpoints, both maps → the SAME equipment ---
	clientYAML, err := d.GenerateClientYAML()
	if err != nil {
		t.Fatalf("GenerateClientYAML: %v", err)
	}
	// Round-trip through the REAL clientconfig.Load — the same code the
	// s7/modbus/opcua readers run at boot — so we prove the mixed-protocol
	// client.yaml is loadable, not merely marshalable.
	tmp := filepath.Join(t.TempDir(), "acme-client.yaml")
	if err := os.WriteFile(tmp, []byte(clientYAML), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := clientconfig.Load(tmp)
	if err != nil {
		t.Fatalf("generated client.yaml rejected by clientconfig.Load: %v\n%s", err, clientYAML)
	}
	if cfg.PLC == nil || len(cfg.PLC.Endpoints) != 2 {
		t.Fatalf("want 2 plc endpoints (one per source protocol), got %+v", cfg.PLC)
	}
	// A mixed-protocol tenant must NOT fold a single plc.protocol — each reader
	// selects its endpoint by name. Empty is the correct mixed-protocol marker.
	if cfg.PLC.Protocol != "" {
		t.Errorf("mixed-protocol tenant should leave plc.protocol empty, got %q", cfg.PLC.Protocol)
	}
	if len(cfg.S7TagMap) != 1 || len(cfg.ModbusTagMap) != 1 {
		t.Fatalf("want one s7 + one modbus tag map, got s7=%d modbus=%d", len(cfg.S7TagMap), len(cfg.ModbusTagMap))
	}
	const wantTopic, wantID = "ACME/SP/LINE1/FILLER", 4201
	if got := cfg.S7TagMap[0]; got.PackMLTopic != wantTopic || got.IDEquipment != wantID {
		t.Errorf("s7 map targets %s/%d, want %s/%d", got.PackMLTopic, got.IDEquipment, wantTopic, wantID)
	}
	if got := cfg.ModbusTagMap[0]; got.PackMLTopic != wantTopic || got.IDEquipment != wantID {
		t.Errorf("modbus map targets %s/%d, want %s/%d", got.PackMLTopic, got.IDEquipment, wantTopic, wantID)
	}
	// The two sources composing ONE equipment IS the point: assert both maps agree
	// on the target equipment (same packml_topic AND same id_equipment).
	if cfg.S7TagMap[0].PackMLTopic != cfg.ModbusTagMap[0].PackMLTopic ||
		cfg.S7TagMap[0].IDEquipment != cfg.ModbusTagMap[0].IDEquipment {
		t.Fatalf("multi-source composition broken: s7 and modbus maps target DIFFERENT equipment (%s/%d vs %s/%d)",
			cfg.S7TagMap[0].PackMLTopic, cfg.S7TagMap[0].IDEquipment,
			cfg.ModbusTagMap[0].PackMLTopic, cfg.ModbusTagMap[0].IDEquipment)
	}

	// --- (2) §C invariant PASSES for both sources ---
	// GenerateClientYAML already ran checkClientAgentConsistency (it errors
	// otherwise, so reaching here is the pass). Re-run it explicitly so the
	// composition proof is self-contained and named.
	if err := d.checkClientAgentConsistency(cfg); err != nil {
		t.Fatalf("§C consistency FAILED for a multi-source equipment — the agent would drop a source: %v", err)
	}

	// --- (3) the two metric_suffixes are DISTINCT and BOTH in the agent map ---
	agentCfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}
	agentSuffix := map[string]bool{}
	for _, e := range agentCfg.RawTagMap {
		agentSuffix[e.MetricSuffix] = true
	}
	// Emitted suffix for each source = <packml_topic><metric> with canonical_prefix stripped.
	s7Suffix := strings.TrimPrefix(cfg.S7TagMap[0].PackMLTopic+cfg.S7TagMap[0].Tags[0].Metric, cfg.CanonicalPrefix)
	mbSuffix := strings.TrimPrefix(cfg.ModbusTagMap[0].PackMLTopic+cfg.ModbusTagMap[0].Tags[0].Metric, cfg.CanonicalPrefix)
	if s7Suffix == mbSuffix {
		t.Fatalf("the two sources must feed DISTINCT metric leaves, both = %q", s7Suffix)
	}
	if !agentSuffix[s7Suffix] {
		t.Errorf("S7 source metric %q missing from agent raw_tag_map %v", s7Suffix, keys(agentSuffix))
	}
	if !agentSuffix[mbSuffix] {
		t.Errorf("Modbus source metric %q missing from agent raw_tag_map %v", mbSuffix, keys(agentSuffix))
	}
	// Sanity on the specific composition the example documents.
	if s7Suffix != "/LINE1/FILLER/Admin/ProdProcessedCount/7/Unit" {
		t.Errorf("S7 source suffix: got %q", s7Suffix)
	}
	if mbSuffix != "/LINE1/FILLER/Status/MachSpeed" {
		t.Errorf("Modbus source suffix: got %q", mbSuffix)
	}

	// The full artifact set must also carry the 5th (client.yaml) artifact.
	art, err := d.Generate(GenerateOptions{})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if art.ClientYAML == nil {
		t.Error("Generate() produced no ClientYAML despite a plc block")
	}
}
