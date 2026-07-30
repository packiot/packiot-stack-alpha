package birth_test

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/birth"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// Canonical fixtures + schema — the SAME goldens the contract §6 says every
// producer tests against (docs/reference/…). Read from the repo so a drift in
// the canonical shape breaks THIS test.
const (
	fixturesDir = "../../../../../docs/reference/fixtures/"
	schemaPath  = "../../../../../docs/reference/schemas/edge-birth-declaration.schema.json"
)

// ── unit: index→role + device_key resolution AT THE EDGE ──────────────────────

func TestCounterMetricProps(t *testing.T) {
	cases := []struct {
		name          string
		metric        string
		wantOK        bool
		wantRole      string
		wantSourceRef string
		wantDeviceKey string
	}{
		// A line's role-typed count leaves (line_roles → /Admin/Prod<Kind>Count/<idx>/Unit).
		{"line consumed→gross", "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/168/Unit",
			true, birth.RoleGross, "idx:168", "CPACK-SC-LINHAS-L5"},
		{"line processed→net", "CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount/169/Unit",
			true, birth.RoleNet, "idx:169", "CPACK-SC-LINHAS-L5"},
		// A member's count leaves (metric_templates).
		{"member consumed→gross", "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
			true, birth.RoleGross, "idx:61", "CPACK-SC-LINHAS-L5-BREYER"},
		{"member processed→net", "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit",
			true, birth.RoleNet, "idx:62", "CPACK-SC-LINHAS-L5-BREYER"},
		{"member defective→scrap", "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdDefectiveCount/63/Unit",
			true, birth.RoleScrap, "idx:63", "CPACK-SC-LINHAS-L5-BREYER"},
		{"bisnago line", "BISNAGO/SP/LINHAS/L71/Admin/ProdConsumedCount/671/Unit",
			true, birth.RoleGross, "idx:671", "BISNAGO-SP-LINHAS-L71"},
		// Non-counter / non-conformant metrics get NO properties (fail-closed).
		{"speed metric", "CPACK/SC/LINHAS/L5/BREYER/Status/MachSpeed", false, "", "", ""},
		{"state metric", "CPACK/SC/LINHAS/L5/BREYER/Status/StateCurrent", false, "", "", ""},
		{"bdSeq", "bdSeq", false, "", "", ""},
		{"bare line count (no idx)", "CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount", false, "", "", ""},
		{"unknown Count kind", "CPACK/SC/LINHAS/L5/Admin/ProdMysteryCount/9/Unit", false, "", "", ""},
		{"non-Unit tail", "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/9/Box", false, "", "", ""},
		{"non-integer idx", "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/x/Unit", false, "", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ps, ok := birth.CounterMetricProps(tc.metric)
			if ok != tc.wantOK {
				t.Fatalf("ok: got %v, want %v", ok, tc.wantOK)
			}
			if !tc.wantOK {
				if ps != nil {
					t.Fatalf("non-counter metric must carry no properties, got %+v", ps)
				}
				return
			}
			got := map[string]string{}
			for i, k := range ps.GetKeys() {
				got[k] = ps.GetValues()[i].GetStringValue()
			}
			if got[birth.PropCounterRole] != tc.wantRole {
				t.Errorf("counter_role: got %q, want %q", got[birth.PropCounterRole], tc.wantRole)
			}
			if got[birth.PropSourceRef] != tc.wantSourceRef {
				t.Errorf("source_ref: got %q, want %q", got[birth.PropSourceRef], tc.wantSourceRef)
			}
			if got[birth.PropDeviceKey] != tc.wantDeviceKey {
				t.Errorf("device_key: got %q, want %q", got[birth.PropDeviceKey], tc.wantDeviceKey)
			}
		})
	}
}

// ── end-to-end: the agent's birth for a descriptor validates + groups by device ──

// descriptorTagMap models the canonical suffixes clientdescriptor.GenerateAgentConfig
// emits for a line (line_roles) + a member (count templates) + a non-count leaf.
// Key = metric SUFFIX (what the tee sends); value = SparkPlug datatype.
var descriptorTagMap = map[string]sparkplug.DataType{
	"/LINHAS/L5/Admin/ProdConsumedCount/168/Unit":        sparkplug.DataType_Double,
	"/LINHAS/L5/Admin/ProdProcessedCount/169/Unit":       sparkplug.DataType_Double,
	"/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit":  sparkplug.DataType_Double,
	"/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit": sparkplug.DataType_Double,
	"/LINHAS/L5/BREYER/Admin/ProdDefectiveCount/63/Unit": sparkplug.DataType_Double,
	"/LINHAS/L5/BREYER/Status/MachSpeed":                 sparkplug.DataType_Double,
}

const testPrefix = "CPACK/SC"
const testGroup = "CPACK"
const testEdgeNode = "sparkplug-agent-cpack"

// mapResolver implements session.Resolver over descriptorTagMap: suffix → full
// canonical name (prefix prepended, like the real newResolver) + datatype.
type mapResolver struct{}

func (mapResolver) Resolve(suffix string) (string, sparkplug.DataType, bool) {
	dt, ok := descriptorTagMap[suffix]
	if !ok {
		return "", 0, false
	}
	return testPrefix + suffix, dt, true
}

func birthSnapshot() []rawtag.RawTag {
	var snap []rawtag.RawTag
	for suffix := range descriptorTagMap {
		snap = append(snap, rawtag.RawTag{Metric: suffix, Value: 42.0, Quality: true, TsMillis: 1782849957000})
	}
	return snap
}

func TestBuildDefinitiveBirth_ValidatesAndGroups(t *testing.T) {
	pub := session.New(mapResolver{}, aliasmap.New(), session.WithDefinitiveBirth(true))
	pub.NewConnection()

	nbirth, err := pub.BuildNBIRTH(birthSnapshot())
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}

	decl := birth.DeclarationFromNBIRTH(testGroup, testEdgeNode, nbirth)
	if err := decl.Validate(); err != nil {
		t.Fatalf("emitted birth does not validate against the schema: %v", err)
	}

	// Two devices: the line (2 role metrics) and the member (3 role metrics). The
	// MachSpeed + bdSeq metrics carry no role and are NOT in the declaration.
	byDevice := map[string][]birth.BirthMetric{}
	for _, d := range decl.Devices {
		byDevice[d.DeviceKey] = d.Metrics
	}
	if len(byDevice) != 2 {
		t.Fatalf("device count: got %d (%v), want 2", len(byDevice), deviceKeys(decl))
	}

	assertRoles(t, byDevice, "CPACK-SC-LINHAS-L5", map[string]string{
		"idx:168": birth.RoleGross,
		"idx:169": birth.RoleNet,
	})
	assertRoles(t, byDevice, "CPACK-SC-LINHAS-L5-BREYER", map[string]string{
		"idx:61": birth.RoleGross,
		"idx:62": birth.RoleNet,
		"idx:63": birth.RoleScrap,
	})

	// Every role metric declared a valid alias (>=1) and the Double datatype.
	for dk, ms := range byDevice {
		for _, m := range ms {
			if m.Alias < 1 {
				t.Errorf("%s: metric %q has alias %d (< 1)", dk, m.Name, m.Alias)
			}
			if m.Datatype != "Double" {
				t.Errorf("%s: metric %q datatype: got %q, want Double", dk, m.Name, m.Datatype)
			}
		}
	}
}

// The flag OFF ⇒ the birth is byte-clean: no metric carries properties, so the
// declaration projection is empty. This is the no-op-deploy guarantee.
func TestDefinitiveBirthOff_NoProperties(t *testing.T) {
	pub := session.New(mapResolver{}, aliasmap.New()) // no WithDefinitiveBirth
	pub.NewConnection()

	nbirth, err := pub.BuildNBIRTH(birthSnapshot())
	if err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}
	for _, m := range nbirth.GetMetrics() {
		if m.GetProperties() != nil {
			t.Fatalf("flag OFF but metric %q carries properties %+v", m.GetName(), m.GetProperties())
		}
	}
	if decl := birth.DeclarationFromNBIRTH(testGroup, testEdgeNode, nbirth); len(decl.Devices) != 0 {
		t.Fatalf("flag OFF: declaration should be empty, got %d devices", len(decl.Devices))
	}
}

// DDATA carries alias+value only — never the birth-only name/role/properties
// (contract §5). This holds even in definitive mode.
func TestDDATA_CarriesNoBirthProperties(t *testing.T) {
	pub := session.New(mapResolver{}, aliasmap.New(), session.WithDefinitiveBirth(true))
	pub.NewConnection()
	if _, err := pub.BuildNBIRTH(birthSnapshot()); err != nil {
		t.Fatalf("BuildNBIRTH: %v", err)
	}
	ndata, err := pub.BuildNDATA(birthSnapshot())
	if err != nil {
		t.Fatalf("BuildNDATA: %v", err)
	}
	for _, m := range ndata.GetMetrics() {
		if m.GetName() != "" {
			t.Errorf("DDATA metric resent a name %q (birth-only)", m.GetName())
		}
		if m.GetProperties() != nil {
			t.Errorf("DDATA metric alias %d carries properties (birth-only)", m.GetAlias())
		}
		if m.GetAlias() < 1 {
			t.Errorf("DDATA metric missing its alias routing key")
		}
	}
}

// ── goldens + schema conformance (the shared canonical fixtures) ──────────────

// The canonical golden fixtures MUST strict-unmarshal into our Declaration
// (additionalProperties:false via DisallowUnknownFields) and pass Validate — so
// our emitted shape and the shared golden can never drift.
func TestGoldenFixturesConform(t *testing.T) {
	cases := []struct {
		file      string
		group     string
		deviceKey string
	}{
		{"cpack-birth-example.json", "CPACK", "CPACK-SC-LINHAS-L5"},
		{"bisnago-birth-example.json", "BISNAGO", "BISNAGO-SP-LINHAS-L71"},
	}
	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			raw, err := os.ReadFile(fixturesDir + tc.file)
			if err != nil {
				t.Skipf("canonical fixture not reachable (%v) — skipping shared-golden check", err)
			}
			dec := json.NewDecoder(bytes.NewReader(raw))
			dec.DisallowUnknownFields() // = schema additionalProperties:false
			var decl birth.Declaration
			if err := dec.Decode(&decl); err != nil {
				t.Fatalf("golden %s does not fit birth.Declaration (schema drift): %v", tc.file, err)
			}
			if err := decl.Validate(); err != nil {
				t.Fatalf("golden %s fails Validate: %v", tc.file, err)
			}
			if decl.GroupID != tc.group {
				t.Errorf("group_id: got %q, want %q", decl.GroupID, tc.group)
			}
			found := false
			for _, d := range decl.Devices {
				if d.DeviceKey == tc.deviceKey {
					found = true
				}
			}
			if !found {
				t.Errorf("golden %s: expected a device_key %q, got %v", tc.file, tc.deviceKey, deviceKeys(decl))
			}
		})
	}
}

// The counter_role + datatype enums our Validate enforces MUST equal the schema
// file's enums — a drift guard tying the Go mirror to the real schema.
func TestSchemaEnumsInSync(t *testing.T) {
	raw, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Skipf("schema not reachable (%v) — skipping enum-sync check", err)
	}
	var schema struct {
		Defs struct {
			Metric struct {
				Properties struct {
					CounterRole struct {
						Enum []string `json:"enum"`
					} `json:"counter_role"`
					Datatype struct {
						Enum []string `json:"enum"`
					} `json:"datatype"`
				} `json:"properties"`
			} `json:"metric"`
		} `json:"$defs"`
	}
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("parse schema: %v", err)
	}
	wantRoles := map[string]bool{birth.RoleGross: true, birth.RoleNet: true, birth.RoleScrap: true}
	if len(schema.Defs.Metric.Properties.CounterRole.Enum) != len(wantRoles) {
		t.Fatalf("schema counter_role enum %v != our roles %v",
			schema.Defs.Metric.Properties.CounterRole.Enum, keys(wantRoles))
	}
	for _, r := range schema.Defs.Metric.Properties.CounterRole.Enum {
		if !wantRoles[r] {
			t.Errorf("schema counter_role %q not in our closed enum", r)
		}
	}
	// datatype: every schema token must be one our datatypeName can produce.
	for _, dt := range schema.Defs.Metric.Properties.Datatype.Enum {
		var decl = birth.Declaration{
			GroupID: "g", EdgeNodeID: "n",
			Devices: []birth.Device{{DeviceKey: "d", Metrics: []birth.BirthMetric{
				{Alias: 1, CounterRole: birth.RoleGross, Datatype: dt},
			}}},
		}
		if err := decl.Validate(); err != nil {
			t.Errorf("schema datatype %q rejected by Validate: %v", dt, err)
		}
	}
}

// ── helpers ───────────────────────────────────────────────────────────────────

func assertRoles(t *testing.T, byDevice map[string][]birth.BirthMetric, deviceKey string, wantByRef map[string]string) {
	t.Helper()
	ms, ok := byDevice[deviceKey]
	if !ok {
		t.Fatalf("missing device %q", deviceKey)
	}
	got := map[string]string{}
	for _, m := range ms {
		got[m.SourceRef] = m.CounterRole
	}
	if len(got) != len(wantByRef) {
		t.Fatalf("%s: metric count got %d, want %d", deviceKey, len(got), len(wantByRef))
	}
	for ref, role := range wantByRef {
		if got[ref] != role {
			t.Errorf("%s: source_ref %s → role %q, want %q", deviceKey, ref, got[ref], role)
		}
	}
}

func deviceKeys(d birth.Declaration) []string {
	var out []string
	for _, dev := range d.Devices {
		out = append(out, dev.DeviceKey)
	}
	return out
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}
