package birthbind_test

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
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

// birthPayload re-hydrates one device's fixture metrics into a SparkPlug B
// DBIRTH payload. counter_role rides in properties (contract §3); device_key is
// carried as the SparkPlug <device_id> (the deviceID arg to ApplyBirth) — the
// common case where the device fixes identity and no per-metric device_key
// override is needed.
func birthPayload(dev fixtureDevice) *sparkplug.Payload {
	p := &sparkplug.Payload{}
	for _, m := range dev.Metrics {
		metric := &sparkplug.Metric{
			Name:  ptr(m.Name),
			Alias: ptr(m.Alias),
		}
		if m.CounterRole != "" {
			metric.Properties = &sparkplug.PropertySet{
				Keys: []string{birthbind.PropCounterRole},
				Values: []*sparkplug.PropertyValue{
					{Value: &sparkplug.PropertyValue_StringValue{StringValue: m.CounterRole}},
				},
			}
		}
		p.Metrics = append(p.Metrics, metric)
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

	// device_key → id_equipment, as packml_register (the SSoT) would resolve.
	// L5 = 40004 is the contract's worked example (Appendix B).
	resolver := birthbind.MapResolver{
		"CPACK-SC-LINHAS-L5":        40004,
		"CPACK-SC-LINHAS-L5-BREYER": 40010,
	}
	table := birthbind.NewTable(resolver)

	for _, dev := range fx.Devices {
		table.ApplyBirth(fx.EdgeNodeID, dev.DeviceKey, birthPayload(dev), nil)
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
		b, ok := table.Lookup(fx.EdgeNodeID, alias)
		if !ok {
			t.Fatalf("alias %d: expected a live binding, got none", alias)
		}
		got := routed{IDEquipment: b.IDEquipment, Role: b.Role, Value: value}
		if got != want[alias] {
			t.Errorf("alias %d routed to %+v, want %+v", alias, got, want[alias])
		}
	}

	// Fail-closed: an alias never declared at birth has no binding → the caller
	// requests a rebirth and drops the sample (contract §5).
	if _, ok := table.Lookup(fx.EdgeNodeID, 9999); ok {
		t.Errorf("unbound alias 9999 must not resolve")
	}
}

// TestBirthBoundRouting_Bisnago drives the numeric-counter client golden — the
// dumb tee resolved index→role at the edge and emits role-typed metrics, so the
// consumer path is identical to a native producer.
func TestBirthBoundRouting_Bisnago(t *testing.T) {
	fx := loadFixture(t, "bisnago-birth-example.json")

	resolver := birthbind.MapResolver{
		"BISNAGO-SP-LINHAS-L71": 40071,
	}
	table := birthbind.NewTable(resolver)
	for _, dev := range fx.Devices {
		table.ApplyBirth(fx.EdgeNodeID, dev.DeviceKey, birthPayload(dev), nil)
	}

	want := map[uint64]routed{
		670: {40071, birthbind.RoleGross, 500000},
		671: {40071, birthbind.RoleNet, 480000},
	}
	ddata := map[uint64]int64{670: 500000, 671: 480000}
	for alias, value := range ddata {
		b, ok := table.Lookup(fx.EdgeNodeID, alias)
		if !ok {
			t.Fatalf("alias %d: expected a live binding, got none", alias)
		}
		got := routed{IDEquipment: b.IDEquipment, Role: b.Role, Value: value}
		if got != want[alias] {
			t.Errorf("alias %d routed to %+v, want %+v", alias, got, want[alias])
		}
	}
}

// TestApplyBirth_FailClosed covers the three fail-closed skips: an unresolvable
// device_key, an unknown counter_role, and a non-counter metric (no role).
func TestApplyBirth_FailClosed(t *testing.T) {
	// Resolver deliberately knows NOTHING → device_key never resolves.
	table := birthbind.NewTable(birthbind.MapResolver{})
	p := &sparkplug.Payload{
		Metrics: []*sparkplug.Metric{
			// counter with a valid role but unresolvable device_key
			metricWithRole("L9/gross", 1, "gross"),
			// unknown role
			metricWithRole("L9/weird", 2, "banana"),
			// non-counter: no counter_role property at all
			{Name: ptr("L9/Status/MachSpeed"), Alias: ptr(uint64(3))},
		},
	}
	bound, skipped := table.ApplyBirth("edge-x", "UNKNOWN-DEVICE", p, nil)
	if bound != 0 {
		t.Errorf("bound = %d, want 0 (nothing should resolve)", bound)
	}
	// alias 1 (unresolvable) + alias 2 (bad role) are skips; alias 3 (non-counter)
	// is silently ignored, not counted as a skip.
	if skipped != 2 {
		t.Errorf("skipped = %d, want 2", skipped)
	}
	for _, alias := range []uint64{1, 2, 3} {
		if _, ok := table.Lookup("edge-x", alias); ok {
			t.Errorf("alias %d must remain unbound (fail-closed)", alias)
		}
	}
}

// TestApplyBirth_PerMetricDeviceKeyOverride verifies properties["device_key"]
// overrides the SparkPlug <device_id> fallback (contract §3).
func TestApplyBirth_PerMetricDeviceKeyOverride(t *testing.T) {
	table := birthbind.NewTable(birthbind.MapResolver{"OVERRIDE-KEY": 555})
	m := metricWithRole("x/net", 7, "net")
	m.Properties.Keys = append(m.Properties.Keys, birthbind.PropDeviceKey)
	m.Properties.Values = append(m.Properties.Values,
		&sparkplug.PropertyValue{Value: &sparkplug.PropertyValue_StringValue{StringValue: "OVERRIDE-KEY"}})

	// deviceID fallback is a DIFFERENT key the resolver doesn't know — proving
	// the per-metric override wins.
	bound, _ := table.ApplyBirth("edge-y", "DEVICE-ID-FALLBACK", &sparkplug.Payload{Metrics: []*sparkplug.Metric{m}}, nil)
	if bound != 1 {
		t.Fatalf("bound = %d, want 1 (override key must resolve)", bound)
	}
	b, ok := table.Lookup("edge-y", 7)
	if !ok || b.IDEquipment != 555 || b.Role != birthbind.RoleNet {
		t.Errorf("lookup = %+v ok=%v, want {555 net}", b, ok)
	}
}

func metricWithRole(name string, alias uint64, role string) *sparkplug.Metric {
	return &sparkplug.Metric{
		Name:  ptr(name),
		Alias: ptr(alias),
		Properties: &sparkplug.PropertySet{
			Keys: []string{birthbind.PropCounterRole},
			Values: []*sparkplug.PropertyValue{
				{Value: &sparkplug.PropertyValue_StringValue{StringValue: role}},
			},
		},
	}
}
