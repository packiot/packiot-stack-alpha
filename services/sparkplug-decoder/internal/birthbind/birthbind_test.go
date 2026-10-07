package birthbind_test

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// ── Golden fixture shape (docs/reference/schemas/edge-birth-declaration.schema.json) ──
// edge-transformer (consumer) and every producer test against the SAME fixtures;
// that shared golden is the compatibility guarantee (contract §6). We decode the
// LOGICAL declaration then re-hydrate it into SparkPlug B birth payloads — the
// exact wire shape ApplyBirth consumes at runtime — so this test exercises the
// real property-extraction path, not a shortcut.

type fixture struct {
	GroupID    string          `json:"group_id"`
	EdgeNodeID string          `json:"edge_node_id"`
	Devices    []fixtureDevice `json:"devices"`
}

type fixtureDevice struct {
	DeviceKey string          `json:"device_key"`
	Metrics   []fixtureMetric `json:"metrics"`
}

type fixtureMetric struct {
	Name        string `json:"name"`
	Alias       uint64 `json:"alias"`
	Datatype    string `json:"datatype"`
	CounterRole string `json:"counter_role"`
	SourceRef   string `json:"source_ref"`
}

func ptr[T any](v T) *T { return &v }

// nbirthPayload re-hydrates the whole fixture into ONE node-scoped NBIRTH — the
// sparkplug-agent's real shape: every counter metric carries counter_role AND its
// declared device_key as properties (contract §3; ADR-0061 D1).
func nbirthPayload(fx fixture) *sparkplug.Payload {
	p := &sparkplug.Payload{}
	for _, dev := range fx.Devices {
		for _, m := range dev.Metrics {
			p.Metrics = append(p.Metrics, metricWithRole(m.Name, m.Alias, m.CounterRole, dev.DeviceKey))
		}
	}
	return p
}

// loadFixture ascends from the test's working dir to find the shared golden
// under docs/reference/fixtures, so the test works whether run from the module
// dir or the repo root.
func loadFixture(t *testing.T, name string) fixture {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		cand := filepath.Join(dir, "docs", "reference", "fixtures", name)
		if _, err := os.Stat(cand); err == nil {
			f, err := os.Open(cand)
			if err != nil {
				t.Fatalf("open %s: %v", cand, err)
			}
			defer f.Close()
			b, err := io.ReadAll(f)
			if err != nil {
				t.Fatalf("read %s: %v", cand, err)
			}
			var fx fixture
			if err := json.Unmarshal(b, &fx); err != nil {
				t.Fatalf("unmarshal %s: %v", cand, err)
			}
			return fx
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("fixture %q not found ascending from working dir", name)
		}
		dir = parent
	}
}

// routed is the tuple the DATA path emits for a bound alias: exactly what
// ADR-0046 step 1 promises — (id_equipment, counter_role, value) with no
// metric-name parsing.
type routed struct {
	IDEquipment int
	Role        birthbind.Role
	Value       int64
}

// TestBirthBoundRouting_CPACK drives the CPACK golden (a line device with
// gross+net from two counters, and a machine device with gross+net+scrap),
// then feeds synthetic DDATA aliases and asserts each routes to the correct
// (id_equipment, counter_role, value).
func TestBirthBoundRouting_CPACK(t *testing.T) {
	fx := loadFixture(t, "cpack-birth-example.json")

	// device_key → (id_equipment, id_enterprise), as core.device_bindings resolves (ADR-0061).
	// L5 = 40004 is the contract's worked example (Appendix B).
	table := birthbind.NewTable(entResolver{
		"dk_00000000000000000000000000040004": {IDEquipment: 40004, IDEnterprise: 3},
		"dk_00000000000000000000000000040010": {IDEquipment: 40010, IDEnterprise: 3},
	})
	if res := table.ApplyBirth(fx.GroupID, fx.EdgeNodeID, "", true, nbirthPayload(fx), nil); res.Bound != 5 || res.Skipped() != 0 {
		t.Fatalf("ApplyBirth = %+v, want 5 bound, 0 skipped", res)
	}

	// Synthetic DDATA: alias → value. Values mirror the contract's Appendix B.
	ddata := map[uint64]int64{
		10: 396066, // L5 gross
		11: 365852, // L5 net
		20: 111111, // BREYER net
		21: 222222, // BREYER gross
		22: 333,    // BREYER scrap
	}
	want := map[uint64]routed{
		10: {40004, birthbind.RoleGross, 396066},
		11: {40004, birthbind.RoleNet, 365852},
		20: {40010, birthbind.RoleNet, 111111},
		21: {40010, birthbind.RoleGross, 222222},
		22: {40010, birthbind.RoleScrap, 333},
	}

	for alias, value := range ddata {
		b, ok := table.Lookup(fx.GroupID, fx.EdgeNodeID, alias)
		if !ok {
			t.Fatalf("alias %d: expected a live binding, got none", alias)
		}
		got := routed{IDEquipment: b.IDEquipment, Role: b.Role, Value: value}
		if got != want[alias] {
			t.Errorf("alias %d routed to %+v, want %+v", alias, got, want[alias])
		}
		if b.IDEnterprise != 3 {
			t.Errorf("alias %d: tenant = %d, want 3 (from the binding, D3)", alias, b.IDEnterprise)
		}
	}

	// Fail-closed: an alias never declared at birth has no binding → the caller
	// requests a rebirth and drops the sample (contract §5).
	if _, ok := table.Lookup(fx.GroupID, fx.EdgeNodeID, 9999); ok {
		t.Errorf("unbound alias 9999 must not resolve")
	}
}

// TestBirthBoundRouting_Bisnago drives the numeric-counter client golden — the
// dumb tee resolved index→role at the edge and emits role-typed metrics, so the
// consumer path is identical to a native producer.
func TestBirthBoundRouting_Bisnago(t *testing.T) {
	fx := loadFixture(t, "bisnago-birth-example.json")

	table := birthbind.NewTable(birthbind.MapResolver{"dk_00000000000000000000000000040071": 40071})
	table.ApplyBirth(fx.GroupID, fx.EdgeNodeID, "", true, nbirthPayload(fx), nil)

	want := map[uint64]routed{
		670: {40071, birthbind.RoleGross, 500000},
		671: {40071, birthbind.RoleNet, 480000},
	}
	ddata := map[uint64]int64{670: 500000, 671: 480000}
	for alias, value := range ddata {
		b, ok := table.Lookup(fx.GroupID, fx.EdgeNodeID, alias)
		if !ok {
			t.Fatalf("alias %d: expected a live binding, got none", alias)
		}
		got := routed{IDEquipment: b.IDEquipment, Role: b.Role, Value: value}
		if got != want[alias] {
			t.Errorf("alias %d routed to %+v, want %+v", alias, got, want[alias])
		}
	}
}

// TestApplyBirth_FailClosed covers every fail-closed outcome: an unresolvable
// key, an unknown role, a counter with NO declared key (even when the topic has a
// <device_id> — no fallback, ADR-0061 P2), and a non-counter (ignored, uncounted).
func TestApplyBirth_FailClosed(t *testing.T) {
	const known = "dk_0000000000000000000000000000000a"
	table := birthbind.NewTable(birthbind.MapResolver{known: 10, "UNKNOWN-DEVICE": 11})
	p := &sparkplug.Payload{
		Metrics: []*sparkplug.Metric{
			metricWithRole("L9/gross", 1, "gross", "dk_ffffffffffffffffffffffffffffffff"), // no binding
			metricWithRole("L9/weird", 2, "banana", known),                                // bad role
			metricWithRole("L9/net", 4, "net", ""),                                        // undeclared
			{Name: ptr("L9/Status/MachSpeed"), Alias: ptr(uint64(3))},                     // non-counter
		},
	}
	// deviceID "UNKNOWN-DEVICE" IS in the resolver: proves it is never used as a key.
	res := table.ApplyBirth("G", "edge-x", "UNKNOWN-DEVICE", false, p, nil)
	want := birthbind.BirthResult{Unresolved: 1, BadRole: 1, NoKey: 1}
	if res != want {
		t.Errorf("ApplyBirth = %+v, want %+v", res, want)
	}
	for _, alias := range []uint64{1, 2, 3, 4} {
		if _, ok := table.Lookup("G", "edge-x", alias); ok {
			t.Errorf("alias %d must remain unbound (fail-closed)", alias)
		}
	}
}

// TestTable_ScopesAndRebirth: bindings are scoped by (group_id, edge_node) — two
// tenants reusing an edge-node name never see each other's aliases; an NBIRTH
// replaces the node's bindings (aliases are re-issued), a DBIRTH extends them;
// LookupName finds the same binding by the birth-declared name.
func TestTable_ScopesAndRebirth(t *testing.T) {
	const ka, kb = "dk_000000000000000000000000000000a1", "dk_000000000000000000000000000000b1"
	table := birthbind.NewTable(entResolver{ka: {IDEquipment: 1, IDEnterprise: 3}, kb: {IDEquipment: 2, IDEnterprise: 5}})
	nb := func(name string, alias uint64, key string) *sparkplug.Payload {
		return &sparkplug.Payload{Metrics: []*sparkplug.Metric{metricWithRole(name, alias, "gross", key)}}
	}
	table.ApplyBirth("CPACK", "agent", "", true, nb("CPACK/L1/gross", 7, ka), nil)
	table.ApplyBirth("BISPHARMA", "agent", "", true, nb("BISPHARMA/L1/gross", 7, kb), nil)

	if b, _ := table.Lookup("CPACK", "agent", 7); b.IDEquipment != 1 || b.IDEnterprise != 3 {
		t.Errorf("CPACK alias 7 = %+v, want equipment 1 / enterprise 3", b)
	}
	if b, _ := table.Lookup("BISPHARMA", "agent", 7); b.IDEquipment != 2 || b.IDEnterprise != 5 {
		t.Errorf("BISPHARMA alias 7 = %+v, want equipment 2 / enterprise 5", b)
	}
	if b, ok := table.LookupName("CPACK", "agent", "CPACK/L1/gross"); !ok || b.IDEquipment != 1 {
		t.Errorf("LookupName = %+v ok=%v, want equipment 1", b, ok)
	}
	if _, ok := table.LookupName("BISPHARMA", "agent", "CPACK/L1/gross"); ok {
		t.Error("a name must not resolve across groups")
	}

	// DBIRTH extends; NBIRTH replaces.
	table.ApplyBirth("CPACK", "agent", "dev1", false, nb("CPACK/L2/gross", 8, ka), nil)
	if _, ok := table.Lookup("CPACK", "agent", 7); !ok {
		t.Error("DBIRTH must not drop the node's other bindings")
	}
	table.ApplyBirth("CPACK", "agent", "", true, nb("CPACK/L3/gross", 9, ka), nil)
	if _, ok := table.Lookup("CPACK", "agent", 7); ok {
		t.Error("NBIRTH must drop the node's previous aliases")
	}
	if _, ok := table.LookupName("CPACK", "agent", "CPACK/L1/gross"); ok {
		t.Error("NBIRTH must drop the node's previous names")
	}
	if table.Len() != 2 { // CPACK alias 9 + BISPHARMA alias 7
		t.Errorf("Len = %d, want 2", table.Len())
	}
}

// entResolver is a test DeviceResolver that also knows the tenant (like refdata).
type entResolver map[string]birthbind.Device

func (r entResolver) Resolve(k string) (birthbind.Device, bool) {
	d, ok := r[k]
	return d, ok
}

// metricWithRole builds a birth counter metric; deviceKey "" declares none.
func metricWithRole(name string, alias uint64, role, deviceKey string) *sparkplug.Metric {
	ps := &sparkplug.PropertySet{
		Keys:   []string{birthbind.PropCounterRole},
		Values: []*sparkplug.PropertyValue{{Value: &sparkplug.PropertyValue_StringValue{StringValue: role}}},
	}
	if deviceKey != "" {
		ps.Keys = append(ps.Keys, birthbind.PropDeviceKey)
		ps.Values = append(ps.Values, &sparkplug.PropertyValue{Value: &sparkplug.PropertyValue_StringValue{StringValue: deviceKey}})
	}
	return &sparkplug.Metric{Name: ptr(name), Alias: ptr(alias), Properties: ps}
}

// TestApplyBirth_DeclaredRolesBeyondCounters: a non-counter with a declared role and
// key binds (ADR-0061 D2), a counter's Declared defaults to counter.<role>, and a
// malformed role is rejected.
func TestApplyBirth_DeclaredRolesBeyondCounters(t *testing.T) {
	const k = "dk_000000000000000000000000000000d1"
	table := birthbind.NewTable(birthbind.MapResolver{k: 7})
	withRole := func(name string, alias uint64, role string) *sparkplug.Metric {
		sv := func(v string) *sparkplug.PropertyValue {
			return &sparkplug.PropertyValue{Value: &sparkplug.PropertyValue_StringValue{StringValue: v}}
		}
		return &sparkplug.Metric{Name: ptr(name), Alias: ptr(alias), Properties: &sparkplug.PropertySet{
			Keys: []string{birthbind.PropRole, birthbind.PropDeviceKey}, Values: []*sparkplug.PropertyValue{sv(role), sv(k)}}}
	}
	res := table.ApplyBirth("G", "n", "", true, &sparkplug.Payload{Metrics: []*sparkplug.Metric{
		withRole("L/Status/StateCurrent", 1, "state.current"),
		withRole("L/Status/Weird", 2, "Not A Role"),
		metricWithRole("L/Admin/ProdConsumedCount/1/Unit", 3, "gross", k),
	}}, nil)
	if res.Bound != 2 || res.BadRole != 1 {
		t.Fatalf("ApplyBirth = %+v, want 2 bound / 1 bad_role", res)
	}
	if b, _ := table.Lookup("G", "n", 1); b.Declared != "state.current" || b.Role != "" || b.IDEquipment != 7 {
		t.Errorf("state binding = %+v", b)
	}
	if b, _ := table.Lookup("G", "n", 3); b.Declared != "counter.gross" || b.Role != birthbind.RoleGross {
		t.Errorf("counter binding = %+v", b)
	}
}
