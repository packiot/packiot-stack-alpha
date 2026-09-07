package clientdescriptor

import (
	"reflect"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// wizardNoTemplatesYAML is a descriptor exactly as the CS-Admin wizard authors
// it: equipment + a plc s7_tag_map, but NO metric_templates block (the wizard
// does not collect the canonical leaf set). Before the empty-templates fallback
// this synthesized ZERO agent raw_tag_map suffixes, so the client⇄agent §C check
// rejected every s7 tag ("N reader metrics have no matching raw_tag_map
// metric_suffix"). The two s7 tags reference a SUBSET of the DEFAULT member
// leaves, so once the fallback kicks in the §C invariant holds (§C is reader→
// agent — the default's extra suffixes never reject a reader tag).
//
//	member M1 (topic ACME/SP/LINE1/M1, count_index 5), prefix ACME/SP →
//	  the s7 tags emit these two suffixes, both present in the default synthesis
//	    /LINE1/M1/Status/MachSpeed
//	    /LINE1/M1/Admin/ProdProcessedCount/5/Unit
const wizardNoTemplatesYAML = `
tenant: ACME
enterprise_id: 9
canonical:
  prefix: ACME/SP
mapping:
  count_index_default_mode: equipment_id
agent:
  edge_node_id: acme-edge
  internal_broker: tcp://mosquitto:1883
  uplink_broker: tcp://ingest:1883
tee:
  ingest_url: https://localhost:8444/v1/tags
equipment:
  - topic: ACME/SP/LINE1
    id_equipment: 9000
    tp_equipment: 3
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

// TestGenerateProfile_EmptyMetricTemplatesFallsBackToDefault proves the fix: a
// wizard-authored descriptor with an EMPTY metric_templates now synthesizes the
// default member + line leaves, and the ADR-0045 §C client⇄agent consistency
// check passes for a matching s7_tag_map. It also asserts the stored descriptor
// is never mutated (the fallback is applied at the generation boundary only).
func TestGenerateProfile_EmptyMetricTemplatesFallsBackToDefault(t *testing.T) {
	d, err := Parse([]byte(wizardNoTemplatesYAML))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	// Precondition: the descriptor really does carry NO metric_templates.
	if len(d.MetricTemplates.Line) != 0 || len(d.MetricTemplates.Member) != 0 {
		t.Fatalf("precondition failed: descriptor should have empty metric_templates, got %+v", d.MetricTemplates)
	}

	// (1) the generated profile carries the scaffold default templates verbatim.
	profile, err := d.GenerateProfile()
	if err != nil {
		t.Fatalf("GenerateProfile: %v", err)
	}
	if !reflect.DeepEqual(profile.MetricTemplates, DefaultMetricTemplates()) {
		t.Errorf("empty templates should fall back to DefaultMetricTemplates()\n got: %+v\nwant: %+v",
			profile.MetricTemplates, DefaultMetricTemplates())
	}

	// (2) synthesis now produces the FULL default member leaves (three production
	// counters + speed + state, count leaves keyed by {idx}=5) and the full default
	// line leaves (bare counters + speed + state + Parameter30700).
	memberSuffixes := synthSuffixes(t, profile, "/LINE1/M1", tenantprofile.ClassMember, 9001)
	for _, want := range []string{
		"/LINE1/M1/Admin/ProdConsumedCount/5/Unit",
		"/LINE1/M1/Admin/ProdProcessedCount/5/Unit",
		"/LINE1/M1/Admin/ProdDefectiveCount/5/Unit",
		"/LINE1/M1/Status/MachSpeed",
		"/LINE1/M1/Status/StateCurrent",
	} {
		if !memberSuffixes[want] {
			t.Errorf("member synthesis missing default leaf %q; got %v", want, suffixKeys(memberSuffixes))
		}
	}
	lineSuffixes := synthSuffixes(t, profile, "/LINE1", tenantprofile.ClassLine, 9000)
	for _, want := range []string{
		"/LINE1/Admin/ProdConsumedCount",
		"/LINE1/Admin/ProdProcessedCount",
		"/LINE1/Admin/ProdDefectiveCount",
		"/LINE1/Status/MachSpeed",
		"/LINE1/Status/StateCurrent",
		"/LINE1/Status/Parameter30700",
	} {
		if !lineSuffixes[want] {
			t.Errorf("line synthesis missing default leaf %q; got %v", want, suffixKeys(lineSuffixes))
		}
	}

	// (3) the §C client⇄agent consistency check passes for the matching s7_tag_map
	// (GenerateClientYAML runs checkClientAgentConsistency internally) — the exact
	// path that returned a 400 before the fallback.
	if _, err := d.GenerateClientYAML(); err != nil {
		t.Fatalf("GenerateClientYAML (runs §C check) should pass with default templates, got: %v", err)
	}

	// (4) the fallback is a generation-time concern only — the stored descriptor is
	// left untouched.
	if len(d.MetricTemplates.Line) != 0 || len(d.MetricTemplates.Member) != 0 {
		t.Errorf("stored descriptor MetricTemplates was mutated: %+v", d.MetricTemplates)
	}
}

// TestGenerateProfile_AuthoredMetricTemplatesUntouched proves the guard: a
// descriptor that DOES author metric_templates keeps them verbatim — the default
// never overrides a real authored set. It authors a member leaf set that is
// DISTINCT from the default (a bare non-{idx} count leaf + no MachSpeed), so a
// silent fallback would be detectable.
func TestGenerateProfile_AuthoredMetricTemplatesUntouched(t *testing.T) {
	const authoredYAML = `
tenant: ACME
enterprise_id: 9
canonical:
  prefix: ACME/SP
mapping:
  count_index_default_mode: equipment_id
metric_templates:
  line:
    - {leaf: "/Status/Parameter30700", type: string}
  member:
    - {leaf: "/Admin/ProdConsumedCount/{idx}/Unit", type: long}
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
`
	d, err := Parse([]byte(authoredYAML))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	profile, err := d.GenerateProfile()
	if err != nil {
		t.Fatalf("GenerateProfile: %v", err)
	}
	if !reflect.DeepEqual(profile.MetricTemplates, d.MetricTemplates) {
		t.Errorf("authored metric_templates must be used verbatim\n got: %+v\nwant: %+v",
			profile.MetricTemplates, d.MetricTemplates)
	}
	if reflect.DeepEqual(profile.MetricTemplates, DefaultMetricTemplates()) {
		t.Errorf("authored metric_templates were wrongly replaced by the default")
	}
	// Sanity: synthesis reflects the AUTHORED leaves, not the default ones.
	member := synthSuffixes(t, profile, "/LINE1/M1", tenantprofile.ClassMember, 9001)
	if !member["/LINE1/M1/Admin/ProdConsumedCount/5/Unit"] {
		t.Errorf("member synthesis should use authored leaf; got %v", suffixKeys(member))
	}
	if member["/LINE1/M1/Status/MachSpeed"] {
		t.Errorf("member synthesis leaked the DEFAULT MachSpeed leaf into an authored descriptor")
	}
}

// synthSuffixes runs SynthesizeEquipment and returns its suffixes as a set.
func synthSuffixes(t *testing.T, p *tenantprofile.Profile, seg string, class tenantprofile.EquipClass, id int) map[string]bool {
	t.Helper()
	metrics, err := p.SynthesizeEquipment(seg, class, id)
	if err != nil {
		t.Fatalf("SynthesizeEquipment(%q): %v", seg, err)
	}
	out := make(map[string]bool, len(metrics))
	for _, m := range metrics {
		out[m.Suffix] = true
	}
	return out
}

func suffixKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
