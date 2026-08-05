package clientdescriptor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

// plcDescriptorYAML is a minimal single-line-with-one-member tenant that carries
// a plc block with a small s7_tag_map. Crucially, its two S7 tag metrics are
// authored to line up with the metrics the equipment templates synthesize for
// that member:
//
//	member M1 (topic ACME/SP/LINE1/M1, count_index 5), prefix ACME/SP →
//	  agent raw_tag_map suffixes  /LINE1/M1/Status/MachSpeed
//	                              /LINE1/M1/Admin/ProdProcessedCount/5/Unit
//	  agent FullName(prefix)      ACME/SP/LINE1/M1/Status/MachSpeed  (etc)
//
// The s7_tag_map's packml_topic (ACME/SP/LINE1/M1) + each tag.metric therefore
// equals a synthesized agent metric — the ADR-0045 §C invariant holds.
const plcDescriptorYAML = `
tenant: ACME
enterprise_id: 9
canonical:
  prefix: ACME/SP
mapping:
  count_index_default_mode: equipment_id
metric_templates:
  member:
    - {leaf: "/Status/MachSpeed", type: double}
    - {leaf: "/Admin/ProdProcessedCount/{idx}/Unit", type: double}
agent:
  edge_node_id: acme-edge
  internal_broker: tcp://mosquitto:1883
  uplink_broker: tcp://ingest:1883
tee:
  ingest_url: https://localhost:8444/v1/tags
equipment:
  - topic: ACME/SP/LINE1/M1
    id_equipment: 9001
    tp_equipment: 1
    id_unit: 9001
    count_index: {value: 5, confidence: confirmed}
plc:
  endpoints:
    - name: line1-plc
      protocol: s7
      host_ref: "secret://packiot/staging/acme/line1-host"
      rack: 0
      slot: 1
      polling_interval: 1s
  s7_tag_map:
    - endpoint: line1-plc
      packml_topic: ACME/SP/LINE1/M1
      id_equipment: 9001
      tags:
        - {metric: "/Status/MachSpeed", db: 1, offset: 8, type: real}
        - {metric: "/Admin/ProdProcessedCount/5/Unit", db: 1, offset: 0, type: dint}
`

// TestGenerateClientYAML_RoundTripsAndAligns is the ADR-0045 P2 acceptance gate:
// a descriptor's plc.s7_tag_map generates a client.yaml that (a) round-trips
// through the REAL clientconfig.Load — the same code the s7-reader runs at boot —
// and (b) every metric that client.yaml produces is present in the SAME
// descriptor's agent raw_tag_map, so the agent won't drop the reader's tags.
func TestGenerateClientYAML_RoundTripsAndAligns(t *testing.T) {
	d, err := Parse([]byte(plcDescriptorYAML))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	// --- (a) round-trip: generate → write → clientconfig.Load ---
	clientYAML, err := d.GenerateClientYAML()
	if err != nil {
		t.Fatalf("GenerateClientYAML: %v", err)
	}
	tmp := filepath.Join(t.TempDir(), "acme-client.yaml")
	if err := os.WriteFile(tmp, []byte(clientYAML), 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := clientconfig.Load(tmp)
	if err != nil {
		t.Fatalf("generated client.yaml rejected by clientconfig.Load: %v\n%s", err, clientYAML)
	}
	if loaded.TenantID != "acme" {
		t.Errorf("tenant_id: got %q want %q", loaded.TenantID, "acme")
	}
	if loaded.PLC == nil || len(loaded.PLC.Endpoints) != 1 || loaded.PLC.Endpoints[0].Name != "line1-plc" {
		t.Fatalf("plc endpoints did not round-trip: %+v", loaded.PLC)
	}
	if len(loaded.S7TagMap) != 1 || len(loaded.S7TagMap[0].Tags) != 2 {
		t.Fatalf("s7_tag_map did not round-trip: %+v", loaded.S7TagMap)
	}
	// The single-protocol tenant folds its protocol up to plc.protocol.
	if loaded.PLC.Protocol != "s7" {
		t.Errorf("plc.protocol: got %q want %q", loaded.PLC.Protocol, "s7")
	}

	// --- (b) every client.yaml metric is in the agent raw_tag_map ---
	agentCfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}
	// canonical_prefix must round-trip so the reader can strip it.
	if loaded.CanonicalPrefix != "ACME/SP" {
		t.Errorf("canonical_prefix: got %q want %q", loaded.CanonicalPrefix, "ACME/SP")
	}
	// The agent resolves by metric_suffix; the reader emits <packml_topic><metric>
	// with canonical_prefix stripped. Assert that stripped form is a metric_suffix.
	agentSuffix := map[string]bool{}
	for _, e := range agentCfg.RawTagMap {
		agentSuffix[e.MetricSuffix] = true
	}
	found := 0
	for _, m := range loaded.S7TagMap {
		for _, tag := range m.Tags {
			emitted := strings.TrimPrefix(m.PackMLTopic+tag.Metric, loaded.CanonicalPrefix)
			if !agentSuffix[emitted] {
				t.Errorf("reader would emit %q, not in agent metric_suffix set %v", emitted, keys(agentSuffix))
			}
			found++
		}
	}
	if found != 2 {
		t.Fatalf("expected 2 client.yaml metrics, checked %d", found)
	}

	// Generate() must also carry the 5th artifact when plc is present.
	art, err := d.Generate(GenerateOptions{})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if art.ClientYAML == nil {
		t.Error("Generate() produced no ClientYAML despite a plc block")
	}
}

// TestGenerateClientYAML_RejectsUnmappedMetric proves the §C invariant FAILS
// generation (never silently drifts) when a plc tag metric has no matching
// synthesized agent leaf — here a MachSpeed on the wrong count index that the
// member template does not produce.
func TestGenerateClientYAML_RejectsUnmappedMetric(t *testing.T) {
	bad := strings.Replace(plcDescriptorYAML,
		`{metric: "/Admin/ProdProcessedCount/5/Unit", db: 1, offset: 0, type: dint}`,
		`{metric: "/Admin/ProdProcessedCount/999/Unit", db: 1, offset: 0, type: dint}`, 1)
	// Parse itself validates (Validate → GenerateClientYAML), so the mismatch is
	// caught at descriptor-load time — the whole point of failing loud + early.
	_, err := Parse([]byte(bad))
	if err == nil {
		t.Fatal("expected parse/validate to reject an unmapped plc metric, got nil")
	}
	if !strings.Contains(err.Error(), "matching raw_tag_map metric_suffix") {
		t.Errorf("error should name the client⇄agent mismatch, got: %v", err)
	}
	if !strings.Contains(err.Error(), "ProdProcessedCount/999/Unit") {
		t.Errorf("error should name the offending metric, got: %v", err)
	}
}

// TestGenerateClientYAML_OmittedWithoutPLC pins the backward-compat contract: a
// descriptor with no plc block generates the historical four artifacts and no
// client.yaml.
func TestGenerateClientYAML_OmittedWithoutPLC(t *testing.T) {
	noPLC := plcDescriptorYAML[:strings.Index(plcDescriptorYAML, "\nplc:")]
	d, err := Parse([]byte(noPLC))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if d.PLC != nil {
		t.Fatal("expected nil PLC")
	}
	art, err := d.Generate(GenerateOptions{})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if art.ClientYAML != nil {
		t.Errorf("descriptor without plc must not emit client.yaml, got %d bytes", len(art.ClientYAML))
	}
	if _, err := d.GenerateClientYAML(); err == nil {
		t.Error("GenerateClientYAML on a plc-less descriptor should error")
	}
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// counterDeriveDescriptorYAML declares a member whose PLC senses only the NET
// count (infeed_only) — so the descriptor's s7_tag_map ProdProcessedCount tag
// carries counter_derive: infeed_only. The equipment templates emit all three
// count leaves so the agent has raw_tag_map slots for the synthesized siblings.
const counterDeriveDescriptorYAML = `
tenant: ACME
enterprise_id: 9
canonical:
  prefix: ACME/SP
mapping:
  count_index_default_mode: equipment_id
metric_templates:
  member:
    - {leaf: "/Admin/ProdConsumedCount/{idx}/Unit", type: double}
    - {leaf: "/Admin/ProdProcessedCount/{idx}/Unit", type: double}
    - {leaf: "/Admin/ProdDefectiveCount/{idx}/Unit", type: double}
agent:
  edge_node_id: acme-edge
  internal_broker: tcp://mosquitto:1883
  uplink_broker: tcp://ingest:1883
tee:
  ingest_url: https://localhost:8444/v1/tags
equipment:
  - topic: ACME/SP/LINE1/M1
    id_equipment: 9001
    tp_equipment: 1
    id_unit: 9001
    count_index: {value: 5, confidence: confirmed}
plc:
  endpoints:
    - name: line1-plc
      protocol: s7
      host_ref: "secret://packiot/staging/acme/line1-host"
      rack: 0
      slot: 1
  s7_tag_map:
    - endpoint: line1-plc
      packml_topic: ACME/SP/LINE1/M1
      id_equipment: 9001
      tags:
        - {metric: "/Admin/ProdProcessedCount/5/Unit", db: 1, offset: 0, type: dint, counter_derive: infeed_only}
`

// TestCounterDerive_DescriptorToClientYAMLAndAgent proves the ADR-0045
// counter_derive field (1) round-trips descriptor → GenerateClientYAML →
// clientconfig.Load, and (2) the generator STAMPS the mode onto the matching
// agent raw_tag_map entry (the join that lets the agent-side counterderive stage
// see it), while leaving non-count entries unstamped.
func TestCounterDerive_DescriptorToClientYAMLAndAgent(t *testing.T) {
	d, err := Parse([]byte(counterDeriveDescriptorYAML))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	// (1) client.yaml round-trip carries counter_derive on the tag.
	clientYAML, err := d.GenerateClientYAML()
	if err != nil {
		t.Fatalf("GenerateClientYAML: %v", err)
	}
	tmp := filepath.Join(t.TempDir(), "acme-client.yaml")
	if err := os.WriteFile(tmp, []byte(clientYAML), 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := clientconfig.Load(tmp)
	if err != nil {
		t.Fatalf("generated client.yaml rejected: %v\n%s", err, clientYAML)
	}
	if len(loaded.S7TagMap) != 1 || len(loaded.S7TagMap[0].Tags) != 1 {
		t.Fatalf("s7_tag_map did not round-trip: %+v", loaded.S7TagMap)
	}
	if got := loaded.S7TagMap[0].Tags[0].CounterDerive; got != clientconfig.CounterDeriveInfeedOnly {
		t.Errorf("counter_derive did not round-trip: got %q want %q", got, clientconfig.CounterDeriveInfeedOnly)
	}

	// (2) the mode is stamped onto the matching agent raw_tag_map entry (net leaf),
	// and only that entry — the synthesized gross/scrap slots stay unstamped.
	agentCfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}
	modeBySuffix := map[string]string{}
	for _, e := range agentCfg.RawTagMap {
		modeBySuffix[e.MetricSuffix] = e.CounterDerive
	}
	if got := modeBySuffix["/LINE1/M1/Admin/ProdProcessedCount/5/Unit"]; got != "infeed_only" {
		t.Errorf("net leaf counter_derive not stamped: got %q want infeed_only", got)
	}
	if got := modeBySuffix["/LINE1/M1/Admin/ProdConsumedCount/5/Unit"]; got != "" {
		t.Errorf("gross (derived) leaf must NOT be stamped, got %q", got)
	}
}
