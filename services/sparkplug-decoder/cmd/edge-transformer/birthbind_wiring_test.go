package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/analyticspub"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/mqtt"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

type devices map[string]birthbind.Device

func (d devices) Resolve(k string) (birthbind.Device, bool) { v, ok := d[k]; return v, ok }

const (
	keyL5  = "dk_000000000000000000000000000000a5"
	keyBRY = "dk_000000000000000000000000000000b5"
	keyOth = "dk_000000000000000000000000000000c5"
)

func testBinder(t *testing.T, r birthbind.DeviceResolver) *birthBinder {
	t.Helper()
	cfg := &config.Config{BirthBoundRouting: true}
	b := newBirthBinder(cfg, prometheus.NewRegistry(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	b.table = birthbind.NewTable(r)
	return b
}

func counter(name string, alias uint64, role, key string) *sparkplug.Metric {
	sv := func(v string) *sparkplug.PropertyValue {
		return &sparkplug.PropertyValue{Value: &sparkplug.PropertyValue_StringValue{StringValue: v}}
	}
	ps := &sparkplug.PropertySet{Keys: []string{"counter_role"}, Values: []*sparkplug.PropertyValue{sv(role)}}
	if key != "" {
		ps.Keys, ps.Values = append(ps.Keys, "device_key"), append(ps.Values, sv(key))
	}
	return &sparkplug.Metric{Name: &name, Alias: &alias, Properties: ps}
}

var nbirth = mqtt.Topic{GroupID: "CPACK", MessageType: "NBIRTH", EdgeNodeID: "agent"}

// TestBinder_StampsBoundMetricsAndTenant: bound counters get id_equipment + role,
// the envelope gets the binding's tenant; unbound metrics (speed, undeclared
// counter) stay bare; metrics/labels count every outcome.
func TestBinder_StampsBoundMetricsAndTenant(t *testing.T) {
	b := testBinder(t, devices{keyL5: {IDEquipment: 47, IDEnterprise: 3}, keyBRY: {IDEquipment: 53, IDEnterprise: 3}})
	b.onBirth(nbirth, &sparkplug.Payload{Metrics: []*sparkplug.Metric{
		counter("CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/1/Unit", 1, "gross", keyL5),
		counter("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdDefectiveCount/2/Unit", 2, "scrap", keyBRY),
		counter("CPACK/SC/LINHAS/L6/Admin/ProdConsumedCount/3/Unit", 3, "gross", ""), // undeclared
	}})
	env := analyticspub.Envelope{Metrics: []analyticspub.Metric{
		{Name: "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/1/Unit"},
		{Name: "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdDefectiveCount/2/Unit"},
		{Name: "CPACK/SC/LINHAS/L6/Admin/ProdConsumedCount/3/Unit"},
		{Name: "CPACK/SC/LINHAS/L5/Status/MachSpeed"},
	}}
	b.stamp(&env, "CPACK", "agent")

	if env.IDEnterprise == nil || *env.IDEnterprise != 3 {
		t.Fatalf("envelope id_enterprise = %v, want 3", env.IDEnterprise)
	}
	wantIDs := []int{47, 53, 0, 0}
	wantRoles := []string{"counter.gross", "counter.scrap", "", ""}
	for i, m := range env.Metrics {
		got := 0
		if m.IDEquipment != nil {
			got = *m.IDEquipment
		}
		if got != wantIDs[i] || m.Role != wantRoles[i] {
			t.Errorf("metric %d (%s) = (%d, %q), want (%d, %q)", i, m.Name, got, m.Role, wantIDs[i], wantRoles[i])
		}
	}
	if v := testutil.ToFloat64(b.counters.WithLabelValues("cpack", "bound")); v != 2 {
		t.Errorf("bound counter = %v, want 2", v)
	}
	if v := testutil.ToFloat64(b.counters.WithLabelValues("cpack", "no_key")); v != 1 {
		t.Errorf("no_key counter = %v, want 1", v)
	}
	if v := testutil.ToFloat64(b.stamps.WithLabelValues("cpack", "stamped")); v != 1 {
		t.Errorf("stamped envelopes = %v, want 1", v)
	}
}

// TestBinder_MixedTenantRemovesStamps: bindings of two enterprises in one
// envelope = misconfiguration → no stamp survives (fail-closed).
func TestBinder_MixedTenantRemovesStamps(t *testing.T) {
	b := testBinder(t, devices{keyL5: {IDEquipment: 47, IDEnterprise: 3}, keyOth: {IDEquipment: 90, IDEnterprise: 5}})
	b.onBirth(nbirth, &sparkplug.Payload{Metrics: []*sparkplug.Metric{
		counter("A", 1, "gross", keyL5), counter("B", 2, "net", keyOth),
	}})
	env := analyticspub.Envelope{Metrics: []analyticspub.Metric{{Name: "A"}, {Name: "B"}}}
	b.stamp(&env, "CPACK", "agent")
	if env.IDEnterprise != nil || env.Metrics[0].IDEquipment != nil || env.Metrics[1].Role != "" {
		t.Fatalf("mixed-tenant envelope kept stamps: %+v", env)
	}
	if v := testutil.ToFloat64(b.stamps.WithLabelValues("cpack", "mixed_tenant")); v != 1 {
		t.Errorf("mixed_tenant = %v, want 1", v)
	}
}

// TestBinder_OffIsByteIdentical: a nil binder (flag OFF) touches nothing, and an
// unstamped envelope marshals without any of the new keys.
func TestBinder_OffIsByteIdentical(t *testing.T) {
	var b *birthBinder
	b.onBirth(nbirth, &sparkplug.Payload{Metrics: []*sparkplug.Metric{counter("A", 1, "gross", keyL5)}})
	env := analyticspub.Envelope{Timestamp: 1, Gateway: "g", Metrics: []analyticspub.Metric{{Name: "A", Timestamp: 1, Value: 2.0}}}
	b.stamp(&env, "CPACK", "agent")
	raw, _ := json.Marshal(env)
	for _, k := range []string{"id_enterprise", "id_equipment", "role"} {
		if strings.Contains(string(raw), k) {
			t.Errorf("flag OFF envelope carries %q: %s", k, raw)
		}
	}
	if newBirthBinder(&config.Config{}, prometheus.NewRegistry(), slog.Default()) != nil {
		t.Error("BIRTH_BOUND_ROUTING unset must build no binder")
	}
}
