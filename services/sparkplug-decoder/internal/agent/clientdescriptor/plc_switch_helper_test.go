package clientdescriptor

import (
	"encoding/json"
	"strings"
	"testing"
)

// disable flips `enabled: false` onto one fixture endpoint.
func disable(t *testing.T, name string) *Descriptor {
	t.Helper()
	d, err := Parse([]byte(readerDescriptorYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	off := false
	for i := range d.PLC.Endpoints {
		if d.PLC.Endpoints[i].Name == name {
			d.PLC.Endpoints[i].Enabled = &off
		}
	}
	return d
}

// TestPLCSwitchedOffIsNotGenerated: a PLC turned off in CS Admin disappears from
// the reader flow AND client.yaml (with its tag map), the others are untouched,
// and the stored descriptor keeps it.
func TestPLCSwitchedOffIsNotGenerated(t *testing.T) {
	d := disable(t, "PLC_L6")
	flow, err := d.GeneratePlcReaderFlow()
	if err != nil {
		t.Fatalf("flow: %v", err)
	}
	cy, err := d.GenerateClientYAML()
	if err != nil {
		t.Fatalf("client.yaml: %v", err)
	}
	for name, out := range map[string]string{"reader flow": string(flow), "client.yaml": cy} {
		if strings.Contains(out, "PLC_L6") {
			t.Errorf("%s still contains the switched-off PLC_L6", name)
		}
		if !strings.Contains(out, "S7 S8") {
			t.Errorf("%s lost an enabled PLC", name)
		}
	}
	if len(d.PLC.Endpoints) != 3 {
		t.Errorf("the stored descriptor must keep all 3 endpoints, has %d", len(d.PLC.Endpoints))
	}
}

// TestPLCAllSwitchedOffEmitsNoReader: every PLC off ⇒ no reader artifacts.
func TestPLCAllSwitchedOffEmitsNoReader(t *testing.T) {
	d, _ := Parse([]byte(readerDescriptorYAML))
	off := false
	for i := range d.PLC.Endpoints {
		d.PLC.Endpoints[i].Enabled = &off
	}
	art, err := d.Generate(GenerateOptions{})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if len(art.ReaderFlow) != 0 || len(art.ClientYAML) != 0 {
		t.Error("no PLC enabled must emit no reader flow / client.yaml")
	}
}

// TestHelperFlow: nodered_helper emits the helper as reader_flow, with the same
// spot ids, a scrubbed tags tap, a publish path to ingest, and customizations.
func TestHelperFlow(t *testing.T) {
	d, err := Parse([]byte(readerDescriptorYAML + `
nodered_helper: true
customizations:
  - {id: my_in, type: "link in", z: x, links: [cpack_spot_tags], wires: [[my_dbg]]}
  - {id: my_dbg, type: debug, z: x, wires: []}
`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	art, err := d.Generate(GenerateOptions{})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	var nodes []map[string]any
	if err := json.Unmarshal(art.ReaderFlow, &nodes); err != nil {
		t.Fatal(err)
	}
	by := map[string]map[string]any{}
	for _, n := range nodes {
		by[n["id"].(string)] = n
	}
	if by["cpack_helper_in"]["url"] != HelperTagsPath {
		t.Fatalf("helper must listen on %s", HelperTagsPath)
	}
	if by["cpack_s7_0_in"] != nil {
		t.Error("the helper must NOT read PLCs (the Python reader does)")
	}
	if got := linksOf(by["cpack_spot_tags"]); len(got) != 1 || got[0] != "my_in" {
		t.Errorf("tags spot links = %v, want [my_in]", got)
	}
	rules, _ := json.Marshal(by["cpack_spot_tags_scrub"]["rules"])
	for _, p := range []string{`"p":"req"`, `"p":"res"`, `"p":"headers"`} {
		if !strings.Contains(string(rules), p) {
			t.Errorf("scrub must delete %s", p)
		}
	}
	fn, _ := by["cpack_helper_build"]["func"].(string)
	if !strings.Contains(fn, `env.get("INGEST_KEY")`) || strings.Contains(fn, "X-Ingest-Key\": \"") {
		t.Error("publish must read the key from env, never bake it")
	}
	if by["my_in"]["z"] != "cpack_cust_tab" {
		t.Error("customizations render on the customizations tab")
	}
}

// TestHelperFlowRejectsSpotsItDoesNotHave: raw reads/agent responses live in the
// Python reader, so subscribing to them fails generate with the real spot list.
func TestHelperFlowRejectsSpotsItDoesNotHave(t *testing.T) {
	d, _ := Parse([]byte(readerDescriptorYAML + `
nodered_helper: true
customizations:
  - {id: r, type: "link in", z: x, links: [cpack_spot_reads], wires: [[]]}
`))
	_, err := d.Generate(GenerateOptions{})
	if err == nil || !IsAuthoringError(err) || !strings.Contains(err.Error(), "cpack_spot_tags") {
		t.Fatalf("want an AuthoringError listing the helper's spots, got %v", err)
	}
}
