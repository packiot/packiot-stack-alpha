package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// The customer "calculation" the automation team asked for: a line total built
// from TWO specific machines. Before, the shared (multi-tenant) agent hard-wired
// derive=nil, so a rule like this only ever ran in the simulator.
const (
	m1    = "/L1/M1/Admin/ProdProcessedCount/1/Unit"
	m2    = "/L1/M2/Admin/ProdProcessedCount/2/Unit"
	total = "/L1/Admin/ProdProcessedCount/3/Unit"
)

func writeTenant(t *testing.T, dir, group string) {
	t.Helper()
	yaml := "sparkplug:\n  group_id: " + group + "\n  edge_node_id: edge-" + group +
		"\n  packml_topic: \"/" + group + "\"\n  internal_broker: tcp://localhost:1883\n  uplink_broker: tcp://localhost:1883\n" +
		"raw_tag_map:\n"
	for _, s := range []string{m1, m2, total} {
		yaml += "  - metric_suffix: " + s + "\n    type: double\n"
	}
	if err := os.WriteFile(filepath.Join(dir, group+".yaml"), []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
}

func derivingDeps(profiles map[string]*tenantprofile.Profile) buildDeps {
	d := testBuildDeps()
	d.profiles = profiles
	d.deriveErrors = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "td_derive_err"}, []string{"group", "segment", "kind"})
	d.deriveEmitted = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "td_derive_emit"}, []string{"group", "segment"})
	return d
}

func lineTotalProfile(tenant string) *tenantprofile.Profile {
	return &tenantprofile.Profile{
		Tenant: tenant,
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/L1", Emit: []string{total}, Type: "double",
			Expr: &tenantprofile.ExprSource{Expr: "m1 + m2", Vars: map[string]string{"m1": m1, "m2": m2}},
		}},
	}
}

func storeValue(p *pipeline, suffix string) (float64, bool) {
	for _, tg := range p.store.Snapshot() {
		if tg.Metric == p.cfg.Sparkplug.PackMLTopic+suffix || tg.Metric == suffix {
			v, ok := tg.Value.(float64)
			return v, ok
		}
	}
	return 0, false
}

// TestMultiTenantDerive_RuleRunsOnlyForItsTenant: ALPHA has a rule and gets
// total = m1 + m2 (inputs arriving in SEPARATE batches — the latch); BETA, same
// tags, no profile, is untouched (no deriver built = the historical path).
func TestMultiTenantDerive_RuleRunsOnlyForItsTenant(t *testing.T) {
	dir := t.TempDir()
	writeTenant(t, dir, "ALPHA")
	writeTenant(t, dir, "BETA")
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))
	deps := derivingDeps(map[string]*tenantprofile.Profile{"ALPHA": lineTotalProfile("ALPHA")})

	ps, err := buildTenantPipelines(dir, deps)
	if err != nil {
		t.Fatalf("buildTenantPipelines: %v", err)
	}
	byGroup := map[string]*pipeline{}
	for _, p := range ps {
		defer p.ob.Close()
		byGroup[p.groupID] = p
	}
	for g, p := range byGroup {
		p.ingest([]rawtag.RawTag{{Metric: m1, Value: 10.0, TsMillis: 1}})
		p.ingest([]rawtag.RawTag{{Metric: m2, Value: 5.0, TsMillis: 2}})
		_ = g
	}

	if v, ok := storeValue(byGroup["ALPHA"], total); !ok || v != 15 {
		t.Fatalf("ALPHA line total = %v (found=%v), want 15 = m1 + m2", v, ok)
	}
	if got := testutil.ToFloat64(deps.deriveEmitted.WithLabelValues("ALPHA", "/L1")); got < 1 {
		t.Errorf("derive emitted metric for ALPHA = %v, want ≥1 (observability wired)", got)
	}
	if _, ok := storeValue(byGroup["BETA"], total); ok {
		t.Fatal("BETA has no rule but a line total was synthesized — derive leaked across tenants")
	}
	if byGroup["BETA"] == nil || byGroup["ALPHA"] == nil {
		t.Fatal("both tenants must build")
	}
}

// TestMultiTenantDerive_NoRulesIsNoOp: a profile WITHOUT derived rules (every real
// tenant today) builds no deriver — accepted/total are exactly the old path's.
func TestMultiTenantDerive_NoRulesIsNoOp(t *testing.T) {
	dir := t.TempDir()
	writeTenant(t, dir, "ALPHA")
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))
	deps := derivingDeps(map[string]*tenantprofile.Profile{"ALPHA": {Tenant: "ALPHA"}})
	ps, err := buildTenantPipelines(dir, deps)
	if err != nil {
		t.Fatalf("buildTenantPipelines: %v", err)
	}
	p := ps[0]
	defer p.ob.Close()
	acc, tot := p.ingest([]rawtag.RawTag{{Metric: m1, Value: 10.0, TsMillis: 1}, {Metric: m2, Value: 5.0, TsMillis: 1}})
	if acc != 2 || tot != 2 {
		t.Fatalf("accepted/total = %d/%d, want 2/2", acc, tot)
	}
	if _, ok := storeValue(p, total); ok {
		t.Fatal("no rules, yet a derived total appeared")
	}
}

// TestMultiTenantDerive_SavedRulesWinAndAllowlist: rules saved in the hub (the
// DB source) are used over the file profile, and a computed tag that is NOT in
// the tenant's tag map is allowlisted automatically (else it'd be dropped).
func TestMultiTenantDerive_SavedRulesWinAndAllowlist(t *testing.T) {
	dir := t.TempDir()
	writeTenant(t, dir, "ALPHA")
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))
	custom := "/L1/Admin/M1TimesTwo/0/Unit" // not in ALPHA's raw_tag_map
	deps := derivingDeps(map[string]*tenantprofile.Profile{"ALPHA": lineTotalProfile("ALPHA")})
	deps.tenantRules = func(_ context.Context, group string) ([]tenantprofile.DerivedRule, bool, error) {
		return []tenantprofile.DerivedRule{{
			Segment: "/L1", Emit: []string{custom}, Type: "double",
			Expr: &tenantprofile.ExprSource{Expr: "m1 * 2", Vars: map[string]string{"m1": m1}},
		}}, true, nil
	}
	ps, err := buildTenantPipelines(dir, deps)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	p := ps[0]
	defer p.ob.Close()
	p.ingest([]rawtag.RawTag{{Metric: m1, Value: 21.0, TsMillis: 1}, {Metric: m2, Value: 1.0, TsMillis: 1}})
	if v, ok := storeValue(p, custom); !ok || v != 42 {
		t.Fatalf("saved rule m1*2 = %v (found=%v), want 42 (and allowlisted)", v, ok)
	}
	if _, ok := storeValue(p, total); ok {
		t.Fatal("the file profile's rule ran although saved rules exist — saved must win")
	}
}

// TestMultiTenantDerive_SavedRulesErrorFallsBack: a DB/generate failure keeps the
// file profile's rules — never an agent crash, never silently no rules.
func TestMultiTenantDerive_SavedRulesErrorFallsBack(t *testing.T) {
	dir := t.TempDir()
	writeTenant(t, dir, "ALPHA")
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))
	deps := derivingDeps(map[string]*tenantprofile.Profile{"ALPHA": lineTotalProfile("ALPHA")})
	deps.tenantRules = func(context.Context, string) ([]tenantprofile.DerivedRule, bool, error) {
		return nil, false, errors.New("db down")
	}
	ps, err := buildTenantPipelines(dir, deps)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	p := ps[0]
	defer p.ob.Close()
	p.ingest([]rawtag.RawTag{{Metric: m1, Value: 10.0, TsMillis: 1}, {Metric: m2, Value: 5.0, TsMillis: 2}})
	if v, ok := storeValue(p, total); !ok || v != 15 {
		t.Fatalf("fallback file rule = %v (found=%v), want 15", v, ok)
	}
}
