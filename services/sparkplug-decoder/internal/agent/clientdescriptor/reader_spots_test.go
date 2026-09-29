package clientdescriptor

import (
	"encoding/json"
	"strings"
	"testing"
)

func genFlow(t *testing.T, extra string) map[string]map[string]any {
	t.Helper()
	d, err := Parse([]byte(readerDescriptorYAML + extra))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	out, err := d.GeneratePlcReaderFlow()
	if err != nil {
		t.Fatalf("GeneratePlcReaderFlow: %v", err)
	}
	var nodes []map[string]any
	if err := json.Unmarshal(out, &nodes); err != nil {
		t.Fatalf("flow is not a JSON array: %v", err)
	}
	byID := map[string]map[string]any{}
	for _, n := range nodes {
		id, _ := n["id"].(string)
		if _, dup := byID[id]; dup {
			t.Fatalf("duplicate node id %q in generated flow", id)
		}
		byID[id] = n
	}
	return byID
}

func wiredTo(n map[string]any, out int, target string) bool {
	b, _ := json.Marshal(n["wires"])
	var w [][]string
	_ = json.Unmarshal(b, &w)
	if out >= len(w) {
		return false
	}
	for _, t := range w[out] {
		if t == target {
			return true
		}
	}
	return false
}

func linksOf(n map[string]any) []string {
	b, _ := json.Marshal(n["links"])
	var l []string
	_ = json.Unmarshal(b, &l)
	return l
}

// TestReaderSpotsContract pins the spot ids/kinds the customize UI mirrors
// (customize/src/lib/node-red-spots.ts). Changing one is a UI-breaking change.
func TestReaderSpotsContract(t *testing.T) {
	want := map[string]SpotKind{
		"reads": SpotTap, "tags": SpotTap, "ingest_result": SpotTap,
		"ingest_error": SpotTap, "publish": SpotEntry,
	}
	if len(ReaderSpots) != len(want) {
		t.Fatalf("ReaderSpots has %d entries, want %d", len(ReaderSpots), len(want))
	}
	for _, s := range ReaderSpots {
		if want[s.Key] != s.Kind {
			t.Errorf("spot %q kind = %q, want %q", s.Key, s.Kind, want[s.Key])
		}
	}
	if SpotID("cpack", "tags") != "cpack_spot_tags" {
		t.Errorf("SpotID shape changed: %q", SpotID("cpack", "tags"))
	}
}

// TestReaderSpotsWiredAsTaps proves every spot exists on the READER tab and the
// taps are EXTRA targets — the core wires (source→normalize→POST→switch) survive.
func TestReaderSpotsWiredAsTaps(t *testing.T) {
	f := genFlow(t, "")
	for _, s := range ReaderSpots {
		n := f[SpotID("cpack", s.Key)]
		if n == nil {
			t.Fatalf("spot %q missing", s.Key)
		}
		if n["z"] != "cpack_reader_tab" {
			t.Errorf("spot %q on tab %v, want the reader tab", s.Key, n["z"])
		}
	}
	norm, http, sw := f["cpack_reader_norm"], f["cpack_reader_http"], f["cpack_reader_route"]
	if !wiredTo(norm, 0, "cpack_reader_http") || !wiredTo(norm, 0, "cpack_spot_tags_scrub") {
		t.Errorf("normalize must feed BOTH the POST and the tags scrubber: %v", norm["wires"])
	}
	if wiredTo(norm, 0, "cpack_spot_tags") {
		t.Error("normalize must NOT feed the tags tap directly — its msg carries the X-Ingest-Key header")
	}
	scrub := f["cpack_spot_tags_scrub"]
	rules, _ := json.Marshal(scrub["rules"])
	if !wiredTo(scrub, 0, "cpack_spot_tags") ||
		!strings.Contains(string(rules), `"p":"headers"`) || !strings.Contains(string(rules), `"p":"url"`) {
		t.Errorf("scrubber must delete msg.headers + msg.url and feed the tags tap: %v", scrub)
	}
	if !wiredTo(http, 0, "cpack_reader_route") || !wiredTo(http, 0, "cpack_spot_ingest_result") {
		t.Errorf("POST must feed BOTH the status switch and the result tap: %v", http["wires"])
	}
	if !wiredTo(sw, 1, "cpack_reader_err") || !wiredTo(sw, 1, "cpack_spot_ingest_error") {
		t.Errorf("switch else-branch must feed BOTH the error debug and the error tap: %v", sw["wires"])
	}
	if wiredTo(sw, 0, "cpack_spot_ingest_error") {
		t.Error("the 2xx branch must NOT feed the error tap")
	}
	if !wiredTo(f["cpack_spot_publish"], 0, "cpack_reader_norm") {
		t.Error("publish entry must feed the normalize function")
	}
	// Every PLC source that feeds normalize also feeds the reads tap.
	sources := 0
	for _, n := range f {
		if n["z"] == "cpack_reader_tab" && wiredTo(n, 0, "cpack_reader_norm") && n["type"] != "link in" {
			sources++
			if !wiredTo(n, 0, "cpack_spot_reads") {
				t.Errorf("source %v feeds normalize but not the reads tap", n["id"])
			}
		}
	}
	if sources == 0 {
		t.Fatal("fixture has no PLC sources feeding normalize — the reads-tap assertion is vacuous")
	}
}

// TestReaderSpotsSubscription proves the back-fill: a customization link-in naming
// a tap lands in that tap's links (the runtime routes on the link-out side), and a
// customization link-out naming publish is mirrored onto the entry.
func TestReaderSpotsSubscription(t *testing.T) {
	f := genFlow(t, `
customizations:
  - {id: sub_b, type: "link in", z: x, links: [cpack_spot_tags], wires: [[dbg]]}
  - {id: sub_a, type: "link in", z: x, links: [cpack_spot_tags, cpack_spot_ingest_error], wires: [[dbg]]}
  - {id: dbg, type: debug, z: x, wires: []}
  - {id: pub, type: "link out", z: x, mode: link, links: [cpack_spot_publish]}
`)
	if got := strings.Join(linksOf(f["cpack_spot_tags"]), ","); got != "sub_a,sub_b" {
		t.Errorf("tags tap links = %q, want sorted sub_a,sub_b", got)
	}
	if got := strings.Join(linksOf(f["cpack_spot_ingest_error"]), ","); got != "sub_a" {
		t.Errorf("ingest_error tap links = %q, want sub_a", got)
	}
	if got := strings.Join(linksOf(f["cpack_spot_publish"]), ","); got != "pub" {
		t.Errorf("publish entry links = %q, want pub", got)
	}
	if got := linksOf(f["cpack_spot_reads"]); len(got) != 0 {
		t.Errorf("unsubscribed tap must have no links, got %v", got)
	}
}

// TestReaderSpotsFailClosed proves a typo'd or wrong-direction spot reference is a
// generate error, never a silently dead wire on the box.
func TestReaderSpotsFailClosed(t *testing.T) {
	cases := map[string]string{
		"unknown spot":        `{id: s, type: "link in", z: x, links: [cpack_spot_tagz], wires: [[]]}`,
		"link-in to entry":    `{id: s, type: "link in", z: x, links: [cpack_spot_publish], wires: [[]]}`,
		"link-out to tap":     `{id: s, type: "link out", z: x, mode: link, links: [cpack_spot_tags]}`,
		"id collides w/ spot": `{id: cpack_spot_tags, type: debug, z: x}`,
	}
	for name, node := range cases {
		t.Run(name, func(t *testing.T) {
			d, err := Parse([]byte(readerDescriptorYAML + "\ncustomizations:\n  - " + node + "\n"))
			if err != nil {
				t.Fatalf("Parse: %v", err)
			}
			if _, err := d.GeneratePlcReaderFlow(); err == nil {
				t.Fatal("want a generate error, got nil")
			}
		})
	}
}

// TestCustomizationDeclaredTabAndSubflowKeepZ proves nodes inside a tab or subflow
// the customizations DECLARE stay there; only foreign-tab nodes are re-homed.
// Before this, a pasted subflow's internals were moved onto the cust tab — the
// subflow instance then ran an empty subflow.
func TestCustomizationDeclaredTabAndSubflowKeepZ(t *testing.T) {
	f := genFlow(t, `
customizations:
  - {id: my_tab, type: tab, label: "OEE export"}
  - {id: on_my_tab, type: debug, z: my_tab, wires: []}
  - {id: sf, type: subflow, name: scale, in: [{wires: [{id: sf_fn}]}], out: [{wires: [{id: sf_fn, port: 0}]}]}
  - {id: sf_fn, type: function, z: sf, func: "return msg;", wires: [[]]}
  - {id: sf_inst, type: "subflow:sf", z: some_exported_tab, wires: [[]]}
  - {id: stray, type: debug, z: some_exported_tab, wires: []}
`)
	checks := map[string]string{
		"on_my_tab": "my_tab",         // declared tab → kept
		"sf_fn":     "sf",             // subflow internal → kept
		"sf_inst":   "cpack_cust_tab", // instance on a foreign tab → re-homed
		"stray":     "cpack_cust_tab", // foreign tab → re-homed
	}
	for id, want := range checks {
		if got := f[id]["z"]; got != want {
			t.Errorf("%s z = %v, want %s", id, got, want)
		}
	}
}
