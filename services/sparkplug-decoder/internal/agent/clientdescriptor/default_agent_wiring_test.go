package clientdescriptor

import (
	"strings"
	"testing"
)

// wizardNoAgentYAML is a descriptor exactly as the CS-Admin wizard's
// blankDescriptor produces it: hierarchy + a plc s7_tag_map, but NEITHER a
// metric_templates NOR an agent: block (the wizard collects neither). Before the
// P0-1 fix, GenerateAgentConfig emitted an agent.yaml with empty
// edge_node_id/internal_broker/uplink_broker; applyAgentConfig pushed it, the
// shared agent's agentcfg.Load rejected it, and buildTenantPipelines returned an
// error → os.Exit(1) → crash-loop → cpack ingest down.
const wizardNoAgentYAML = `
tenant: DUMMY
enterprise_id: 9990001
canonical:
  prefix: DUMMY/SP
mapping:
  count_index_default_mode: equipment_id
tee:
  ingest_url: https://localhost:8444/v1/tags
equipment:
  - topic: DUMMY/SP/LINE1
    id_equipment: 9000
    tp_equipment: 3
  - topic: DUMMY/SP/LINE1/M1
    id_equipment: 9001
    tp_equipment: 1
    id_unit: 9001
    count_index: {value: 9001, confidence: confirmed}
plc:
  endpoints:
    - name: line1-plc
      protocol: s7
      host_ref: "secret://packiot/staging/dummy/line1-host"
      rack: 0
      slot: 1
      polling_interval: 1s
  s7_tag_map:
    - endpoint: line1-plc
      packml_topic: DUMMY/SP/LINE1/M1
      id_equipment: 9001
      tags:
        - {metric: "/Admin/ProdProcessedCount/9001/Unit", db: 1, offset: 0, type: dint}
`

// TestGenerateAgentConfig_NoAgentBlockDefaultsAndValidates proves P0-1's
// prevention layer: a descriptor with NO agent block generates a VALID (Load-able)
// agent config, with the fields defaulted from DefaultAgentWiring. This is the
// exact input that used to produce an unloadable agent.yaml.
func TestGenerateAgentConfig_NoAgentBlockDefaultsAndValidates(t *testing.T) {
	d, err := Parse([]byte(wizardNoAgentYAML))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	// Precondition: the descriptor really has NO agent wiring authored.
	if strings.TrimSpace(d.Agent.EdgeNodeID) != "" || strings.TrimSpace(d.Agent.InternalBroker) != "" || strings.TrimSpace(d.Agent.UplinkBroker) != "" {
		t.Fatalf("precondition failed: descriptor should have an empty agent block, got %+v", d.Agent)
	}

	cfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig must succeed for a no-agent descriptor (P0-1): %v", err)
	}

	// The generated config passes the SAME validation agentcfg.Load applies — so
	// the shared agent will Load it without error.
	if err := cfg.Validate(); err != nil {
		t.Fatalf("generated agent config must be Load-able (Validate passes): %v", err)
	}

	// The defaults are the DefaultAgentWiring values (tenant-derived).
	want := DefaultAgentWiring("DUMMY")
	if cfg.Sparkplug.EdgeNodeID != want.EdgeNodeID {
		t.Errorf("edge_node_id = %q, want defaulted %q", cfg.Sparkplug.EdgeNodeID, want.EdgeNodeID)
	}
	if cfg.Sparkplug.InternalBroker != want.InternalBroker {
		t.Errorf("internal_broker = %q, want defaulted %q", cfg.Sparkplug.InternalBroker, want.InternalBroker)
	}
	if cfg.Sparkplug.UplinkBroker != want.UplinkBroker {
		t.Errorf("uplink_broker = %q, want defaulted %q", cfg.Sparkplug.UplinkBroker, want.UplinkBroker)
	}
	// group_id is always the tenant (not defaulted) and the raw_tag_map is non-empty.
	if cfg.Sparkplug.GroupID != "DUMMY" {
		t.Errorf("group_id = %q, want DUMMY", cfg.Sparkplug.GroupID)
	}
	if len(cfg.RawTagMap) == 0 {
		t.Errorf("raw_tag_map must be non-empty (the s7 tag synthesizes at least one suffix)")
	}

	// The stored descriptor is NOT mutated — defaulting is a generation-boundary
	// concern only (same contract as the metric_templates fallback).
	if strings.TrimSpace(d.Agent.EdgeNodeID) != "" {
		t.Errorf("stored descriptor agent block was mutated: %+v", d.Agent)
	}
}

// TestGenerateAgentConfig_AuthoredAgentUntouched proves explicit agent values win
// over the defaults (no silent override).
func TestGenerateAgentConfig_AuthoredAgentUntouched(t *testing.T) {
	const authoredAgentYAML = `
tenant: DUMMY
enterprise_id: 9990001
canonical:
  prefix: DUMMY/SP
mapping:
  count_index_default_mode: equipment_id
agent:
  edge_node_id: custom-edge-node
  internal_broker: tcp://mosquitto:1883
  uplink_broker: ssl://real-ingest.example:8883
tee:
  ingest_url: https://localhost:8444/v1/tags
equipment:
  - topic: DUMMY/SP/LINE1/M1
    id_equipment: 9001
    tp_equipment: 1
    id_unit: 9001
    count_index: {value: 9001, confidence: confirmed}
plc:
  endpoints:
    - name: line1-plc
      protocol: s7
      host_ref: "secret://packiot/staging/dummy/line1-host"
      rack: 0
      slot: 1
      polling_interval: 1s
  s7_tag_map:
    - endpoint: line1-plc
      packml_topic: DUMMY/SP/LINE1/M1
      id_equipment: 9001
      tags:
        - {metric: "/Admin/ProdProcessedCount/9001/Unit", db: 1, offset: 0, type: dint}
`
	d, err := Parse([]byte(authoredAgentYAML))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	cfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}
	if cfg.Sparkplug.EdgeNodeID != "custom-edge-node" {
		t.Errorf("authored edge_node_id must win; got %q", cfg.Sparkplug.EdgeNodeID)
	}
	if cfg.Sparkplug.UplinkBroker != "ssl://real-ingest.example:8883" {
		t.Errorf("authored uplink_broker must win; got %q", cfg.Sparkplug.UplinkBroker)
	}
}
