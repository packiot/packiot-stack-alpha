package clientdescriptor

import (
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/numeric"
)

// lineRolesDescriptorYAML is a minimal one-line tenant that exercises the
// line_roles path: a tp=3 line binds gross→consumed(idx 168) + net→processed(idx
// 169), plus two ordinary tp=1 station members (distinct indices). It is the
// staging-shaped Bispharma L01 in miniature.
const lineRolesDescriptorYAML = `
tenant: BISTEST
enterprise_id: 4
canonical:
  prefix: BISTEST/SP
mapping:
  count_index_default_mode: equipment_id
metric_templates:
  line:
    - {leaf: "/Admin/ProdProcessedCount", type: double}
    - {leaf: "/Admin/ProdConsumedCount", type: double}
    - {leaf: "/Admin/ProdDefectiveCount", type: double}
  member:
    - {leaf: "/Admin/ProdProcessedCount/{idx}/Unit", type: double}
agent:
  edge_node_id: bistest-edge
tee:
  ingest_url: https://localhost:8444/v1/counters
equipment:
  - topic: BISTEST/SP/LINHAS/L01
    id_equipment: 40001
    tp_equipment: 3
    line_roles:
      - {role: consumed,  count_index: 168, confidence: confirmed}
      - {role: processed, count_index: 169, confidence: confirmed}
  - {topic: BISTEST/SP/LINHAS/L01/S3, id_equipment: 40101, tp_equipment: 1, id_unit: 40101, count_index: {value: 164, confidence: confirmed}}
  - {topic: BISTEST/SP/LINHAS/L01/S4, id_equipment: 40102, tp_equipment: 1, id_unit: 40102, count_index: {value: 165, confidence: confirmed}}
`

// TestLineRoles_GenerateRoutableLeaves proves the whole chain the fix depends on:
// a line's line_roles synthesize numeric-routable count leaves, and
// numeric.BuildIndexFromTagMap resolves each legacy count id to the correct
// canonical role leaf under the LINE topic — so the tee's gross(168)/net(169)
// channels land on the line id_equipment as ProdConsumedCount/ProdProcessedCount.
func TestLineRoles_GenerateRoutableLeaves(t *testing.T) {
	d, err := Parse([]byte(lineRolesDescriptorYAML))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	cfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}

	// The two indexed line-role leaves must be present under the line segment.
	wantSuffixes := map[string]bool{
		"/LINHAS/L01/Admin/ProdConsumedCount/168/Unit":  false, // gross
		"/LINHAS/L01/Admin/ProdProcessedCount/169/Unit": false, // net/good
	}
	for _, e := range cfg.RawTagMap {
		if _, ok := wantSuffixes[e.MetricSuffix]; ok {
			wantSuffixes[e.MetricSuffix] = true
		}
	}
	for s, seen := range wantSuffixes {
		if !seen {
			t.Errorf("raw_tag_map missing line-role leaf %q; got %+v", s, cfg.RawTagMap)
		}
	}

	// numeric routing: 168 → the GROSS (Consumed) leaf, 169 → the NET (Processed)
	// leaf. This is the exact table the agent hands the numeric ingest.
	idx, err := numeric.BuildIndexFromTagMap(cfg.RawTagMap)
	if err != nil {
		t.Fatalf("BuildIndexFromTagMap: %v (a collision here means a duplicate index leaked)", err)
	}
	if got := idx[168].Suffix; !strings.HasSuffix(got, "ProdConsumedCount/168/Unit") {
		t.Errorf("index 168 (gross) routed to %q, want a ProdConsumedCount leaf", got)
	}
	if got := idx[169].Suffix; !strings.HasSuffix(got, "ProdProcessedCount/169/Unit") {
		t.Errorf("index 169 (net) routed to %q, want a ProdProcessedCount leaf", got)
	}
	// The two members' own indices must also route (no regression), distinct.
	if _, ok := idx[164]; !ok {
		t.Errorf("member index 164 not routable")
	}
	if _, ok := idx[165]; !ok {
		t.Errorf("member index 165 not routable")
	}
}

// TestLineRoles_RejectsInvalid pins the Validate guards.
func TestLineRoles_RejectsInvalid(t *testing.T) {
	base := lineRolesDescriptorYAML
	cases := []struct {
		name    string
		mutate  func(string) string
		wantErr string
	}{
		{
			name:    "line_roles on a member (tp=1)",
			mutate:  func(s string) string { return strings.Replace(s, "id_equipment: 40001\n    tp_equipment: 3", "id_equipment: 40001\n    tp_equipment: 1\n    id_unit: 40001", 1) },
			wantErr: "only valid on a line/sector",
		},
		{
			name:    "unknown role",
			mutate:  func(s string) string { return strings.Replace(s, "role: consumed", "role: gross", 1) },
			wantErr: "must be consumed|processed|defective",
		},
		{
			name:    "count_index collides with a member",
			mutate:  func(s string) string { return strings.Replace(s, "count_index: 168", "count_index: 164", 1) },
			wantErr: "already claimed by",
		},
		{
			name:    "bad confidence",
			mutate:  func(s string) string { return strings.Replace(s, "count_index: 169, confidence: confirmed", "count_index: 169, confidence: maybe", 1) },
			wantErr: "must be confirmed|inferred",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Parse([]byte(tc.mutate(base)))
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("error %q does not contain %q", err.Error(), tc.wantErr)
			}
		})
	}
}

// TestLineRoles_InferredGatesCutover proves an inferred line role blocks cutover
// exactly like an inferred member index.
func TestLineRoles_InferredGatesCutover(t *testing.T) {
	y := strings.Replace(lineRolesDescriptorYAML,
		"count_index: 169, confidence: confirmed",
		"count_index: 169, confidence: inferred", 1)
	d, err := Parse([]byte(y))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if inf := d.InferredMembers(); len(inf) != 1 || !strings.Contains(inf[0], "L01") {
		t.Errorf("InferredMembers = %v, want the L01 line flagged", inf)
	}
	if _, err := d.Generate(GenerateOptions{Cutover: true}); err == nil {
		t.Fatal("Generate(Cutover:true) must refuse while a line role is inferred")
	}
}
