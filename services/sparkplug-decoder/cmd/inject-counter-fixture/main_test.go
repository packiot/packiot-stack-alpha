package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The fixture runs against the shared staging broker on every deploy. If any
// of its names lands in a real tenant's group it writes into that tenant's
// live counters (it did: CPACK L5/BREYER, 2026-08 → 2026-09).
func TestFixturePublishesOnlyUnderSyntheticGroup(t *testing.T) {
	for _, name := range []string{consumedMetricName, machSpeedMetricName, lineTopicParam30700Name} {
		if !strings.HasPrefix(name, groupID+"/") {
			t.Errorf("metric %q is outside the fixture group %q", name, groupID)
		}
	}

	tenants, err := filepath.Glob("../../../../docs/clients/tenants/*.yaml")
	if err != nil || len(tenants) == 0 {
		t.Fatalf("no tenant configs found to check against (err=%v)", err)
	}
	groupRe := regexp.MustCompile(`(?m)^\s*group_id:\s*(\S+)`)
	for _, f := range tenants {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range groupRe.FindAllStringSubmatch(string(b), -1) {
			if strings.EqualFold(m[1], groupID) {
				t.Errorf("fixture group %q is a real tenant group (%s)", groupID, filepath.Base(f))
			}
		}
	}
}
