package clientdescriptor

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
)

// bispharmaDescriptorPath locates the shipped bispharma PLC-type example relative
// to THIS test source (runtime.Caller), so the test proves the exact artifact under
// docs/clients/examples/ — not an inline copy that could drift from what a CS
// engineer reads. Five dirs up from the package reaches the repo root.
func bispharmaDescriptorPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	pkgDir := filepath.Dir(thisFile)
	return filepath.Join(pkgDir, "..", "..", "..", "..", "..",
		"docs", "clients", "examples", "bispharma.descriptor.yaml")
}

// TestBispharmaPLCType_ExpandsTypeTimesMembers is the ADR-0050 proof on bispharma's
// real shape: 16 endpoints, one shared plc type, 5 members per line, count index =
// id_equipment. It runs the SHIPPED descriptor through the SAME generation path
// onboard-gen uses and asserts the generator SYNTHESIZES a valid s7_tag_map from
// type × members — no hand-authored tags, offsets from the type, metrics matching
// the agent suffix (§C consistent by construction).
func TestBispharmaPLCType_ExpandsTypeTimesMembers(t *testing.T) {
	// Load runs the full Validate, which builds client.yaml → runs clientconfig's
	// validator AND checkClientAgentConsistency (§C). A pass here means the whole
	// descriptor validates + generates and §C holds — the core ADR-0050 claim.
	d, err := Load(bispharmaDescriptorPath(t))
	if err != nil {
		t.Fatalf("load bispharma example (Load runs full Validate incl. §C): %v", err)
	}

	// --- the expanded s7 tag map: 16 lines × 5 members = 80 entries ---
	s7, err := d.effectiveS7TagMap()
	if err != nil {
		t.Fatalf("effectiveS7TagMap: %v", err)
	}
	const wantEntries = 16 * 5
	if len(s7) != wantEntries {
		t.Fatalf("want %d expanded s7 tag entries (16 lines × 5 members), got %d", wantEntries, len(s7))
	}

	// Every entry is exactly ONE tag: the member's NET count leaf, DB from the type,
	// offset chosen by the member's sensor key, width = the type's word. Assert the
	// full physical+canonical binding for a representative line (L01, ids 100-block).
	wantByTopic := map[string]struct {
		metric string
		offset int
	}{
		"BISPHARMA/SP/LINHAS/L01/S1INFEED": {"/Admin/ProdProcessedCount/101/Unit", 0},  // S1 → 0
		"BISPHARMA/SP/LINHAS/L01/S3":       {"/Admin/ProdProcessedCount/103/Unit", 8},  // S3 → 8
		"BISPHARMA/SP/LINHAS/L01/S4":       {"/Admin/ProdProcessedCount/104/Unit", 12}, // S4 → 12
		"BISPHARMA/SP/LINHAS/L01/S5":       {"/Admin/ProdProcessedCount/105/Unit", 16}, // S5 → 16
		"BISPHARMA/SP/LINHAS/L01/S6OUTPUT": {"/Admin/ProdProcessedCount/106/Unit", 20}, // S6 → 20
	}
	seen := map[string]bool{}
	for _, m := range s7 {
		if len(m.Tags) != 1 {
			t.Fatalf("%s: want exactly 1 synthesized tag, got %d", m.PackMLTopic, len(m.Tags))
		}
		tg := m.Tags[0]
		if tg.DB != 1 {
			t.Errorf("%s: db=%d, want 1 (from the type)", m.PackMLTopic, tg.DB)
		}
		if tg.Type != "dint" {
			t.Errorf("%s: type=%q, want dint (the type's word)", m.PackMLTopic, tg.Type)
		}
		if m.Endpoint == "" {
			t.Errorf("%s: expanded entry must reference its endpoint", m.PackMLTopic)
		}
		if w, ok := wantByTopic[m.PackMLTopic]; ok {
			seen[m.PackMLTopic] = true
			if tg.Metric != w.metric {
				t.Errorf("%s: metric=%q, want %q", m.PackMLTopic, tg.Metric, w.metric)
			}
			if tg.Offset != w.offset {
				t.Errorf("%s: offset=%d, want %d (from the type's sensor_offsets)", m.PackMLTopic, tg.Offset, w.offset)
			}
		}
	}
	for topic := range wantByTopic {
		if !seen[topic] {
			t.Errorf("expected member %q was not expanded into the s7 tag map", topic)
		}
	}

	// --- client.yaml round-trips through the REAL loader the readers run at boot ---
	clientYAML, err := d.GenerateClientYAML()
	if err != nil {
		t.Fatalf("GenerateClientYAML: %v", err)
	}
	tmp := filepath.Join(t.TempDir(), "bispharma-client.yaml")
	if err := os.WriteFile(tmp, []byte(clientYAML), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := clientconfig.Load(tmp)
	if err != nil {
		t.Fatalf("generated client.yaml rejected by clientconfig.Load: %v", err)
	}
	if len(cfg.S7TagMap) != wantEntries {
		t.Errorf("client.yaml s7_tag_map has %d entries, want %d", len(cfg.S7TagMap), wantEntries)
	}
	// A uniform S7 tenant folds a single plc.protocol, and each endpoint inherits
	// the type's rack/slot even though the endpoints declare neither.
	if cfg.PLC == nil || cfg.PLC.Protocol != "s7" {
		t.Fatalf("want folded plc.protocol=s7 (uniform tenant), got %+v", cfg.PLC)
	}
	if len(cfg.PLC.Endpoints) != 16 {
		t.Fatalf("want 16 endpoints, got %d", len(cfg.PLC.Endpoints))
	}
	ep0 := cfg.PLC.Endpoints[0]
	if ep0.Rack == nil || *ep0.Rack != 0 || ep0.Slot == nil || *ep0.Slot != 2 {
		t.Errorf("endpoint %q must inherit rack=0/slot=2 from its type, got rack=%v slot=%v", ep0.Name, ep0.Rack, ep0.Slot)
	}
}

// baseTypedDescriptor builds a minimal single-line typed descriptor in code, so the
// precedence / skip / error paths are exercised without the 96-entry fixture. One
// line with two count members (S1INFEED, S6OUTPUT) on one S7-typed endpoint.
func baseTypedDescriptor() *Descriptor {
	iptr := func(i int) *int { return &i }
	return &Descriptor{
		Tenant:          "ACME",
		EnterpriseID:    42,
		Canonical:       Canonical{Prefix: "ACME/SP"},
		Mapping:         Mapping{CountIndexDefaultMode: "equipment_id"},
		MetricTemplates: DefaultMetricTemplates(),
		Agent: AgentWiring{
			EdgeNodeID:     "acme-edge",
			InternalBroker: "tcp://mosquitto:1883",
			RawTopic:       "acme/raw",
			UplinkBroker:   "ssl://ingest.example.invalid:8883",
		},
		Tee: TeeParams{IngestURL: "https://localhost:8444/v1/tags", TLSInsecure: true},
		Equipment: []Equipment{
			{Topic: "ACME/SP/LINHAS/L01", IDEquipment: 100, TPEquipment: 3},
			{Topic: "ACME/SP/LINHAS/L01/S1INFEED", IDEquipment: 101, TPEquipment: 1, IDUnit: iptr(101)},
			{Topic: "ACME/SP/LINHAS/L01/S6OUTPUT", IDEquipment: 106, TPEquipment: 1, IDUnit: iptr(106)},
		},
		PLC: &DescriptorPLC{
			Types: map[string]PLCType{
				"acme_s7": {
					Protocol:      "s7",
					Rack:          iptr(0),
					Slot:          iptr(1),
					DB:            1,
					Word:          "dint",
					SensorOffsets: map[string]int{"S1": 0, "S6": 20},
				},
			},
			Endpoints: []DescriptorPLCEndpoint{
				{Name: "L01", Type: "acme_s7", HostRef: "10.0.0.5"},
			},
		},
	}
}

// TestPLCType_ExplicitOverridesType proves ADR-0050 precedence: an EXPLICIT
// s7_tag_map entry for an endpoint suppresses the type expansion for that endpoint
// entirely (explicit > type), keeping the escape hatch for an irregular PLC.
func TestPLCType_ExplicitOverridesType(t *testing.T) {
	d := baseTypedDescriptor()
	// An explicit (deliberately non-default) entry on the SAME endpoint.
	d.PLC.S7TagMap = []clientconfig.S7EndpointTags{{
		Endpoint:    "L01",
		PackMLTopic: "ACME/SP/LINHAS/L01/S1INFEED",
		IDEquipment: 101,
		Tags:        []clientconfig.S7Tag{{Metric: "/Admin/ProdProcessedCount/101/Unit", DB: 9, Offset: 999, Type: "dint"}},
	}}
	if err := d.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	s7, err := d.effectiveS7TagMap()
	if err != nil {
		t.Fatalf("effectiveS7TagMap: %v", err)
	}
	// Only the explicit entry survives — the type did NOT expand this endpoint.
	if len(s7) != 1 {
		t.Fatalf("explicit entry must suppress type expansion for its endpoint; want 1 entry, got %d", len(s7))
	}
	if s7[0].Tags[0].DB != 9 || s7[0].Tags[0].Offset != 999 {
		t.Errorf("explicit entry must be kept verbatim (db=9 off=999), got db=%d off=%d", s7[0].Tags[0].DB, s7[0].Tags[0].Offset)
	}
}

// TestPLCType_SkipsMemberWithNoSensorKey proves a member whose sensor key is not in
// the type's sensor_offsets (e.g. a SCRAP member, or one the layout doesn't cover)
// is SKIPPED — a gap, not an error, matching an endpoint with neither type nor tags.
func TestPLCType_SkipsMemberWithNoSensorKey(t *testing.T) {
	d := baseTypedDescriptor()
	iptr := func(i int) *int { return &i }
	// Add a SCRAP member — no leading S<n>, so no sensor key, so no tag.
	d.Equipment = append(d.Equipment, Equipment{
		Topic: "ACME/SP/LINHAS/L01/SCRAP", IDEquipment: 199, TPEquipment: 1, IDUnit: iptr(199),
	})
	if err := d.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	s7, err := d.effectiveS7TagMap()
	if err != nil {
		t.Fatalf("effectiveS7TagMap: %v", err)
	}
	// Still only the two S1/S6 members expand; SCRAP is skipped.
	if len(s7) != 2 {
		t.Fatalf("SCRAP member (no sensor key) must be skipped; want 2 entries, got %d", len(s7))
	}
	for _, m := range s7 {
		if strings.Contains(m.PackMLTopic, "SCRAP") {
			t.Errorf("SCRAP member should not have produced a tag: %s", m.PackMLTopic)
		}
	}
}

// TestPLCType_LinePinResolvesMembers proves the explicit `line:` pin resolves the
// endpoint's members by the line's canonical topic (the alternative to name match).
func TestPLCType_LinePinResolvesMembers(t *testing.T) {
	d := baseTypedDescriptor()
	// Rename the endpoint so NAME no longer matches "L01", and pin the line instead.
	d.PLC.Endpoints[0].Name = "plc-alpha"
	d.PLC.Endpoints[0].Line = "ACME/SP/LINHAS/L01"
	if err := d.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	s7, err := d.effectiveS7TagMap()
	if err != nil {
		t.Fatalf("effectiveS7TagMap: %v", err)
	}
	if len(s7) != 2 {
		t.Fatalf("line pin must resolve the 2 members, got %d entries", len(s7))
	}
	for _, m := range s7 {
		if m.Endpoint != "plc-alpha" {
			t.Errorf("expanded entry must reference the renamed endpoint, got %q", m.Endpoint)
		}
	}
}

// TestPLCType_ValidationErrors covers the descriptor-time guards the type schema
// adds: a dangling type ref, a bad S7 word, an endpoint protocol contradicting its
// type, and a typed endpoint that matches no members.
func TestPLCType_ValidationErrors(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(d *Descriptor)
		wantErr string
	}{
		{
			name:    "dangling type ref",
			mutate:  func(d *Descriptor) { d.PLC.Endpoints[0].Type = "nope" },
			wantErr: `type="nope" must reference a plc.types[] name`,
		},
		{
			name: "bad s7 word",
			mutate: func(d *Descriptor) {
				tp := d.PLC.Types["acme_s7"]
				tp.Word = "float64"
				d.PLC.Types["acme_s7"] = tp
			},
			wantErr: `word="float64" must be dint|int|real`,
		},
		{
			name:    "protocol contradicts type",
			mutate:  func(d *Descriptor) { d.PLC.Endpoints[0].Protocol = "modbus_tcp" },
			wantErr: `contradicts its type`,
		},
		{
			name:    "typed endpoint matches no members",
			mutate:  func(d *Descriptor) { d.PLC.Endpoints[0].Name = "L99" },
			wantErr: "expands to NO members",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := baseTypedDescriptor()
			tc.mutate(d)
			err := d.Validate()
			if err == nil {
				t.Fatalf("want error containing %q, got nil", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErr)
			}
		})
	}
}

// TestPLCType_AmbiguousNameMatchIsRejected proves the guard against a name that
// matches members on two DIFFERENT lines sharing a final segment: the expansion
// must fail (not silently pull a foreign line's members) and point at `line:`.
func TestPLCType_AmbiguousNameMatchIsRejected(t *testing.T) {
	d := baseTypedDescriptor()
	iptr := func(i int) *int { return &i }
	// A SECOND line whose final segment is ALSO "L01" (different parent), with an
	// S1INFEED member — so endpoint name "L01" now matches members on two lines.
	d.Equipment = append(d.Equipment,
		Equipment{Topic: "ACME/SP/OTHER/L01", IDEquipment: 200, TPEquipment: 3},
		Equipment{Topic: "ACME/SP/OTHER/L01/S1INFEED", IDEquipment: 201, TPEquipment: 1, IDUnit: iptr(201)},
	)
	err := d.Validate()
	if err == nil {
		t.Fatal("want ambiguity error, got nil")
	}
	if !strings.Contains(err.Error(), "different lines") {
		t.Fatalf("error %q should flag the ambiguous multi-line name match", err.Error())
	}
	// Pinning the line disambiguates — the SAME descriptor validates once `line:` is set.
	d.PLC.Endpoints[0].Line = "ACME/SP/LINHAS/L01"
	if err := d.Validate(); err != nil {
		t.Fatalf("pinning line: must disambiguate, got %v", err)
	}
}

// TestPLCType_NoTypesIsByteIdentical proves the additive guarantee: a descriptor
// with an EXPLICIT tag map and no types generates the exact same s7 map it always
// did (effectiveS7TagMap returns the explicit entries unchanged).
func TestPLCType_NoTypesIsByteIdentical(t *testing.T) {
	d := baseTypedDescriptor()
	d.PLC.Types = nil
	explicit := []clientconfig.S7EndpointTags{{
		Endpoint:    "L01",
		PackMLTopic: "ACME/SP/LINHAS/L01/S1INFEED",
		IDEquipment: 101,
		Tags:        []clientconfig.S7Tag{{Metric: "/Admin/ProdProcessedCount/101/Unit", DB: 1, Offset: 0, Type: "dint"}},
	}}
	d.PLC.S7TagMap = explicit
	// The endpoint no longer references a type (types are gone) — make it a plain s7.
	d.PLC.Endpoints[0].Type = ""
	d.PLC.Endpoints[0].Protocol = "s7"
	if err := d.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	s7, err := d.effectiveS7TagMap()
	if err != nil {
		t.Fatalf("effectiveS7TagMap: %v", err)
	}
	if len(s7) != 1 || s7[0].Tags[0].Offset != 0 || s7[0].Tags[0].DB != 1 {
		t.Fatalf("no-types path must return the explicit map unchanged, got %+v", s7)
	}
}

// sanity: the fixture path builder points at a real file (fail fast with a clear
// message if the example is renamed/moved).
func TestBispharmaFixtureExists(t *testing.T) {
	p := bispharmaDescriptorPath(t)
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("bispharma example missing at %s: %v (%s)", p, err, fmt.Sprintf("regenerate under docs/clients/examples"))
	}
}
