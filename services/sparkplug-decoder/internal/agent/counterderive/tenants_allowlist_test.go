package counterderive

import (
	"path/filepath"
	"regexp"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// tenantsGlob is the deployed tenant set the shared sparkplug-agent loads
// (compose.staging.yml mounts docs/clients/tenants at /etc/packiot/tenants).
const tenantsGlob = "../../../../../docs/clients/tenants/*.yaml"

var countLeafRe = regexp.MustCompile(`^(.*)/Prod(Consumed|Processed|Defective)Count/([^/]+)/Unit$`)

func loadTenants(t *testing.T) map[string]*agentcfg.Config {
	t.Helper()
	paths, err := filepath.Glob(tenantsGlob)
	if err != nil || len(paths) == 0 {
		t.Fatalf("no tenant configs at %s (err=%v)", tenantsGlob, err)
	}
	out := map[string]*agentcfg.Config{}
	for _, p := range paths {
		cfg, err := agentcfg.Load(p)
		if err != nil {
			t.Fatalf("load %s: %v", p, err)
		}
		out[filepath.Base(p)] = cfg
	}
	return out
}

// TestTenantDerivedSiblingsAreAllowlisted guards the silent-drop trap: Process
// synthesizes a derived count at its leaf-swapped sibling suffix, and that tag then
// travels the same strict raw_tag_map allowlist as a sensed one. A counter_derive
// mode whose siblings are not listed derives a value that is dropped as unmapped,
// so the gross/net/scrap it was declared for never reaches the cloud.
func TestTenantDerivedSiblingsAreAllowlisted(t *testing.T) {
	for name, cfg := range loadTenants(t) {
		allow := map[string]bool{}
		for _, e := range cfg.RawTagMap {
			allow[e.MetricSuffix] = true
		}
		for _, e := range cfg.RawTagMap {
			switch e.CounterDerive {
			case "", ModeFull, ModeNone:
				continue
			}
			m := countLeafRe.FindStringSubmatch(e.MetricSuffix)
			if m == nil {
				continue // a mode on a non-count leaf derives nothing (New ignores it)
			}
			for _, leaf := range []string{"Consumed", "Processed", "Defective"} {
				sib := m[1] + "/Prod" + leaf + "Count/" + m[3] + "/Unit"
				if !allow[sib] {
					t.Errorf("%s: %s declares counter_derive=%s but sibling %s is not in raw_tag_map (derived value would be dropped as unmapped)",
						name, e.MetricSuffix, e.CounterDerive, sib)
				}
			}
		}
	}
}

// TestCPACKSleeveInfeedOnly pins the 2026-10-09 SLEEVE fix: SLEEVE1/2 sense only
// ProdProcessedCount, and legacy reports gross == net for them, so infeed_only
// must synthesize gross := net and scrap := 0 from the deployed cpack.yaml.
func TestCPACKSleeveInfeedOnly(t *testing.T) {
	cfg := loadTenants(t)["cpack.yaml"]
	if cfg == nil {
		t.Fatal("cpack.yaml not found among tenant configs")
	}
	var entries []Entry
	for _, e := range cfg.RawTagMap {
		entries = append(entries, Entry{Suffix: e.MetricSuffix, Mode: e.CounterDerive})
	}
	st := New(entries)
	for _, sleeve := range []struct{ head, idx string }{
		{"/SLEEVE/SLEEVE1/SLEEVE1/Admin", "763"},
		{"/SLEEVE/SLEEVE2/SLEEVE2/Admin", "823"},
	} {
		in := []rawtag.RawTag{{Metric: sleeve.head + "/ProdProcessedCount/" + sleeve.idx + "/Unit", Value: 4242.0, TsMillis: 1, Quality: true}}
		got := map[string]float64{}
		for _, s := range st.Process(in) {
			got[s.Metric] = s.Value.(float64)
		}
		gross := sleeve.head + "/ProdConsumedCount/" + sleeve.idx + "/Unit"
		scrap := sleeve.head + "/ProdDefectiveCount/" + sleeve.idx + "/Unit"
		if v, ok := got[gross]; !ok || v != 4242 {
			t.Errorf("%s: gross = %v (present %v), want 4242", sleeve.head, v, ok)
		}
		if v, ok := got[scrap]; !ok || v != 0 {
			t.Errorf("%s: scrap = %v (present %v), want 0", sleeve.head, v, ok)
		}
	}
}
