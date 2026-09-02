package flowimport

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
)

// loadCPACK loads the real CPACK acceptance flow + the CPACK descriptor.
func loadCPACK(t *testing.T) (*clientdescriptor.Descriptor, []byte) {
	t.Helper()
	flowJSON, err := os.ReadFile(filepath.Join("testdata", "cpack-flow.json"))
	if err != nil {
		t.Fatalf("read flow fixture: %v", err)
	}
	// The descriptor lives in the onboard package's testdata; reference it so the
	// importer runs against the SAME canonical model the generator targets.
	d, err := clientdescriptor.Load(filepath.Join("..", "agent", "onboard", "testdata", "cpack-ready.descriptor.yaml"))
	if err != nil {
		t.Fatalf("load descriptor: %v", err)
	}
	return d, flowJSON
}

func runCPACK(t *testing.T) *Result {
	t.Helper()
	d, flowJSON := loadCPACK(t)
	res, err := Import(flowJSON, Options{Descriptor: d, Tenant: "cpack", Env: "staging"})
	if err != nil {
		t.Fatalf("Import: %v", err)
	}
	return res
}

// TestCPACK_Endpoints asserts the 9 S7 endpoints + 1 modbus endpoint are
// extracted with correct host_ref (secret, never IP), rack, and slot.
func TestCPACK_Endpoints(t *testing.T) {
	res := runCPACK(t)

	var s7Count, modbusCount int
	byName := map[string]clientdescriptor.DescriptorPLCEndpoint{}
	for _, ep := range res.PLC.Endpoints {
		byName[ep.Name] = ep
		switch ep.Protocol {
		case clientdescriptor.PLCProtocolS7:
			s7Count++
		case clientdescriptor.PLCProtocolModbusTCP:
			modbusCount++
		}
	}
	if s7Count != 9 {
		t.Errorf("want 9 S7 endpoints, got %d", s7Count)
	}
	if modbusCount != 1 {
		t.Errorf("want 1 modbus endpoint, got %d", modbusCount)
	}

	// Spot-check rack/slot (S7 L10 is the odd-slot one: rack 0 slot 1; PLC L4 is
	// rack 1 slot 2) and that the host is a secret ref, never the raw IP.
	cases := []struct {
		name string
		rack int
		slot int
	}{
		{"S7 115", 0, 2},
		{"S7 L10", 0, 1},
		{"PLC L4", 1, 2},
	}
	for _, c := range cases {
		ep, ok := byName[c.name]
		if !ok {
			t.Errorf("endpoint %q missing", c.name)
			continue
		}
		if ep.Rack == nil || *ep.Rack != c.rack || ep.Slot == nil || *ep.Slot != c.slot {
			t.Errorf("endpoint %q: rack/slot = %v/%v, want %d/%d", c.name, deref(ep.Rack), deref(ep.Slot), c.rack, c.slot)
		}
		if !strings.HasPrefix(ep.HostRef, "secret://") {
			t.Errorf("endpoint %q: host_ref %q is not a secret:// reference", c.name, ep.HostRef)
		}
	}

	// The modbus endpoint carries its unit_id and a secret host_ref.
	l6, ok := byName["PLC_L6"]
	if !ok {
		t.Fatal("modbus endpoint PLC_L6 missing")
	}
	if l6.UnitID == nil || *l6.UnitID != 1 {
		t.Errorf("PLC_L6 unit_id = %v, want 1", l6.UnitID)
	}

	// No raw IP may appear in any emitted host_ref (secret discipline).
	for _, ep := range res.PLC.Endpoints {
		if strings.Contains(ep.HostRef, "10.135.") {
			t.Errorf("endpoint %q leaked a raw host in host_ref %q", ep.Name, ep.HostRef)
		}
	}

	// The real hosts are surfaced for provisioning (stderr table), one per endpoint.
	if len(res.HostRefs) != 10 {
		t.Errorf("want 10 host provisioning rows, got %d", len(res.HostRefs))
	}
}

// TestCPACK_CanonicalTags asserts the 23 canonical (full-name) S7 tags produce
// the correct {db, offset, type, metric}, split at the canonical equipment path.
func TestCPACK_CanonicalTags(t *testing.T) {
	res := runCPACK(t)

	if res.NumTagsMapped != 23 {
		t.Errorf("want 23 canonical tags mapped, got %d", res.NumTagsMapped)
	}

	// Index the emitted tags by (packml_topic, metric) for exact-value assertions.
	type key struct{ topic, metric string }
	got := map[key]clientconfig.S7Tag{}
	for _, m := range res.PLC.S7TagMap {
		for _, tag := range m.Tags {
			got[key{m.PackMLTopic, tag.Metric}] = tag
		}
	}

	want := []struct {
		topic  string
		metric string
		db     int
		offset int
		typ    string
	}{
		// L8 (endpoint S7 S8) — DINT + one INT (ProdConsumedCount/220 at INT32).
		{"CPACK/SC/LINHAS/L8/DXL", "/Admin/ProdProcessedCount/219/Unit", 1, 0, "dint"},
		{"CPACK/SC/LINHAS/L8/PTH", "/Admin/ProdConsumedCount/220/Unit", 1, 32, "int"},
		{"CPACK/SC/LINHAS/L8/TCX", "/Admin/ProdProcessedCount/221/Unit", 1, 16, "dint"},
		{"CPACK/SC/LINHAS/L8/TEXA", "/Admin/ProdProcessedCount/222/Unit", 1, 20, "dint"},
		// L4 (endpoint PLC L4) — the two-leaf PTH member (Consumed at DINT4, Processed at INT32).
		{"CPACK/SC/LINHAS/L4/BREYER", "/Admin/ProdConsumedCount/88/Unit", 1, 0, "dint"},
		{"CPACK/SC/LINHAS/L4/PTH", "/Admin/ProdConsumedCount/86/Unit", 1, 4, "dint"},
		{"CPACK/SC/LINHAS/L4/PTH", "/Admin/ProdProcessedCount/86/Unit", 1, 32, "int"},
		{"CPACK/SC/LINHAS/L4/TEXA", "/Admin/ProdConsumedCount/84/Unit", 1, 28, "dint"},
		// FLEXO — a /Status/ leaf (not /Admin/), proving the leaf-root split.
		{"CPACK/SC/CELULA9/FLEXO/FLEXO", "/Status/CurMachSpeed", 1, 50, "int"},
		// SLEEVES — non-LINHAS topic path.
		{"CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1", "/Admin/ProdProcessedCount/763/Unit", 1, 0, "dint"},
	}
	for _, w := range want {
		tag, ok := got[key{w.topic, w.metric}]
		if !ok {
			t.Errorf("missing tag %s%s", w.topic, w.metric)
			continue
		}
		if tag.DB != w.db || tag.Offset != w.offset || tag.Type != w.typ {
			t.Errorf("tag %s%s: got {db:%d offset:%d type:%s}, want {db:%d offset:%d type:%s}",
				w.topic, w.metric, tag.DB, tag.Offset, tag.Type, w.db, w.offset, w.typ)
		}
	}
}

// TestCPACK_SuffixContract proves every emitted S7 tag honors the ADR-0045 §C
// key: packml_topic+metric, with canonical.prefix stripped, is a group-relative
// metric_suffix (leads with '/'). This is what lets the tag line up with the
// agent raw_tag_map once the equipment is added to the descriptor.
func TestCPACK_SuffixContract(t *testing.T) {
	d, flowJSON := loadCPACK(t)
	res, err := Import(flowJSON, Options{Descriptor: d})
	if err != nil {
		t.Fatalf("Import: %v", err)
	}
	prefix := d.Canonical.Prefix
	for _, m := range res.PLC.S7TagMap {
		if m.PackMLTopic[:len(prefix)] != prefix {
			t.Errorf("packml_topic %q does not start with canonical.prefix %q", m.PackMLTopic, prefix)
		}
		for _, tag := range m.Tags {
			full := m.PackMLTopic + tag.Metric
			suffix := full[len(prefix):]
			if len(suffix) == 0 || suffix[0] != '/' {
				t.Errorf("tag %s: suffix %q is not group-relative (must lead with '/')", full, suffix)
			}
		}
	}
}

// TestCPACK_UnresolvedFlaggedNotDropped asserts the bare/opaque S7 tags are
// FLAGGED (in the YAML as commented skeletons + as warnings), never dropped: the
// count of canonical + unresolved must equal every parseable vartable row.
func TestCPACK_UnresolvedFlaggedNotDropped(t *testing.T) {
	res := runCPACK(t)

	if res.NumUnresolved == 0 {
		t.Fatal("expected unresolved bare-number tags, got 0")
	}
	// 23 canonical + 32 bare/opaque = 55 total S7 vartable rows (none dropped).
	if total := res.NumTagsMapped + res.NumUnresolved; total != 55 {
		t.Errorf("canonical(%d)+unresolved(%d)=%d, want 55 (no vartable row dropped)",
			res.NumTagsMapped, res.NumUnresolved, total)
	}
	// A specific bare number (514, on S7 115) must appear in the YAML as a comment.
	if !contains(res.YAML, "count-index 514") {
		t.Error("bare-number 514 not surfaced in the emitted YAML")
	}
	// And it must NOT appear as a live s7_tag_map metric (would be an invented binding).
	for _, m := range res.PLC.S7TagMap {
		for _, tag := range m.Tags {
			if contains(tag.Metric, "/514/") {
				t.Errorf("bare number 514 leaked into a live tag %q — must stay a skeleton", tag.Metric)
			}
		}
	}
	if len(res.Warnings) == 0 {
		t.Error("expected warnings for unresolved + modbus skeleton")
	}
}

// TestCPACK_ModbusSkeleton asserts the modbus endpoint is emitted, but its tag
// map is a skeleton comment (block ranges) — no invented register bindings, and
// no zero-tag modbus_tag_map entry (which would fail the clientconfig validator).
func TestCPACK_ModbusSkeleton(t *testing.T) {
	res := runCPACK(t)

	if len(res.PLC.ModbusTagMap) != 0 {
		t.Errorf("modbus_tag_map must be empty (skeleton is a comment), got %d entries", len(res.PLC.ModbusTagMap))
	}
	if res.NumSkeleton != 2 {
		t.Errorf("want 2 modbus block skeletons, got %d", res.NumSkeleton)
	}
	for _, want := range []string{"HoldingRegister block adr 0..79", "InputRegister block adr 0..109", "modbus_tag_map:"} {
		if !contains(res.YAML, want) {
			t.Errorf("emitted YAML missing modbus skeleton fragment %q", want)
		}
	}
}

// TestCPACK_RoundTrip proves the emitted plc: block round-trips through the real
// DescriptorPLC types: the comments are ignored on re-parse, and the structured
// tree re-marshals identically (structural fidelity — the emitted YAML IS a
// faithful DescriptorPLC subtree, not a hand-rolled string).
func TestCPACK_RoundTrip(t *testing.T) {
	res := runCPACK(t)

	var back struct {
		PLC clientdescriptor.DescriptorPLC `yaml:"plc"`
	}
	if err := yaml.Unmarshal([]byte(res.YAML), &back); err != nil {
		t.Fatalf("emitted YAML does not parse into DescriptorPLC: %v", err)
	}
	if len(back.PLC.Endpoints) != len(res.PLC.Endpoints) {
		t.Errorf("round-trip endpoints: got %d, want %d", len(back.PLC.Endpoints), len(res.PLC.Endpoints))
	}
	if len(back.PLC.S7TagMap) != len(res.PLC.S7TagMap) {
		t.Errorf("round-trip s7_tag_map: got %d, want %d", len(back.PLC.S7TagMap), len(res.PLC.S7TagMap))
	}
	// Re-marshal the parsed-back tree and the original; they must be byte-equal.
	a, _ := yaml.Marshal(res.PLC)
	b, _ := yaml.Marshal(back.PLC)
	if string(a) != string(b) {
		t.Errorf("round-trip not byte-identical:\n--- emitted ---\n%s\n--- parsed-back ---\n%s", a, b)
	}
}

// TestAddrParser unit-tests the S7 addr grammar in isolation.
func TestAddrParser(t *testing.T) {
	cases := []struct {
		addr         string
		db, off, bit int
		typ          string
		wantErr      bool
	}{
		{addr: "DB1,DINT0", db: 1, off: 0, typ: "dint"},
		{addr: "DB1,DINT36", db: 1, off: 36, typ: "dint"},
		{addr: "DB1,INT48", db: 1, off: 48, typ: "int"},
		{addr: "DB2,REAL8", db: 2, off: 8, typ: "real"},
		{addr: "DB1,WORD10", db: 1, off: 10, typ: "int"},       // WORD → int
		{addr: "DB1,X4.3", db: 1, off: 4, bit: 3, typ: "bool"}, // bit
		{addr: "DB1,X4", wantErr: true},                        // bit missing .bit
		{addr: "garbage", wantErr: true},
	}
	for _, c := range cases {
		db, off, bit, typ, err := parseS7Addr(c.addr)
		if c.wantErr {
			if err == nil {
				t.Errorf("parseS7Addr(%q): want error, got none", c.addr)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseS7Addr(%q): unexpected error %v", c.addr, err)
			continue
		}
		if db != c.db || off != c.off || bit != c.bit || typ != c.typ {
			t.Errorf("parseS7Addr(%q) = {db:%d off:%d bit:%d typ:%s}, want {db:%d off:%d bit:%d typ:%s}",
				c.addr, db, off, bit, typ, c.db, c.off, c.bit, c.typ)
		}
	}
}

// TestSplitCanonical unit-tests prefix normalization + leaf split (the C-PACK →
// CPACK fixup + the /Admin/ /Status/ split point).
func TestSplitCanonical(t *testing.T) {
	cases := []struct {
		name       string
		prefix     string
		wantTopic  string
		wantMetric string
		wantOK     bool
	}{
		{
			name:       "C-PACK/SC/LINHAS/L8/DXL/Admin/ProdProcessedCount/219/Unit***TRIG_C=I",
			prefix:     "CPACK/SC",
			wantTopic:  "CPACK/SC/LINHAS/L8/DXL",
			wantMetric: "/Admin/ProdProcessedCount/219/Unit",
			wantOK:     true,
		},
		{
			name:       "C-PACK/SC/CELULA9/FLEXO/FLEXO/Status/CurMachSpeed",
			prefix:     "CPACK/SC",
			wantTopic:  "CPACK/SC/CELULA9/FLEXO/FLEXO",
			wantMetric: "/Status/CurMachSpeed",
			wantOK:     true,
		},
		{
			name:   "C-PACK/SC/NoLeafHere",
			prefix: "CPACK/SC",
			wantOK: false,
		},
	}
	for _, c := range cases {
		topic, metric, ok := splitCanonical(c.name, c.prefix)
		if ok != c.wantOK {
			t.Errorf("splitCanonical(%q): ok=%v, want %v", c.name, ok, c.wantOK)
			continue
		}
		if ok && (topic != c.wantTopic || metric != c.wantMetric) {
			t.Errorf("splitCanonical(%q) = (%q,%q), want (%q,%q)", c.name, topic, metric, c.wantTopic, c.wantMetric)
		}
	}
}

func deref(p *int) int {
	if p == nil {
		return -1
	}
	return *p
}

func contains(s, sub string) bool { return strings.Contains(s, sub) }
