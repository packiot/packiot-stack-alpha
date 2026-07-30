// dualpath_equivalence_test.go — ADR-0046 #19a: the cutover-safety proof.
//
// THE CUTOVER, IN ONE SENTENCE. Today the Calc counter KIND is derived by
// string-parsing the metric NAME (isCounterMetricName: "ProdConsumedCount" →
// Consumed). ADR-0046 replaces that with the birth-DECLARED counter_role
// (roleToCounterKind: gross → Consumed). The cutover is byte-safe iff, for every
// counter the stack sees, the two derivations land on the SAME CounterKind.
//
// THREE MAPS MUST AGREE, or the cutover silently reclassifies a counter:
//
//	birth.leafRole        legacy-name substring → role   (PRODUCER, birth.go)
//	roleToCounterKind     role                  → kind   (CONSUMER, main.go)
//	isCounterMetricName   legacy-name substring → kind   (LEGACY parser, main.go)
//
// The identity that must hold, per metric:
//
//	roleToCounterKind( producerRole(name) )  ==  isCounterMetricName(name)
//
// where producerRole(name) is birth.CounterMetricProps' real output. If someone
// edits leafRole, roleToCounterKind, or isCounterMetricName in isolation, this
// test fails and NAMES the offending metric + both kinds. That is the whole
// value: the three maps live in two packages and are easy to drift.
//
// A NOTE ON THE GOLDEN NAMES. The shared golden fixtures
// (docs/reference/fixtures/*-birth-example.json) carry the NEW canonical display
// names ("L5/gross", §5 display-only), which the LEGACY parser does not
// recognise (isCounterMetricName → Unknown). That is not a bug — it is exactly
// WHY the cutover exists: only the birth path can classify a post-cutover metric.
// So the golden sub-test asserts the birth path routes every declared metric
// (roleToCounterKind != Unknown) AND that the legacy parser is deliberately blind
// to the new names. The legacy↔role AGREEMENT (the identity above) is proven on
// the legacy count-leaf names, which is where both paths have an opinion.
package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/birth"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
	calc "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/transforms/calc_production_counters"
)

// producerRole runs the REAL producer path (birth.CounterMetricProps) to get the
// counter_role a legacy count-leaf name would be declared with, then validates it
// through birthbind.ParseRole — the same enum the consumer uses. ok=false for a
// non-counter name (no role), mirroring the producer.
func producerRole(t *testing.T, name string) (birthbind.Role, bool) {
	t.Helper()
	ps, ok := birth.CounterMetricProps(name)
	if !ok {
		return "", false
	}
	keys, vals := ps.GetKeys(), ps.GetValues()
	for i, k := range keys {
		if k == birth.PropCounterRole && i < len(vals) {
			return birthbind.ParseRole(vals[i].GetStringValue())
		}
	}
	return "", false
}

// TestDualPathCounterKindEquivalence is the ADR-0046 #19a cutover-safety proof.
func TestDualPathCounterKindEquivalence(t *testing.T) {
	// ── (1) Legacy descriptor counter metrics — the identity with teeth ──────
	// Real CPACK-shaped count-leaf topics (machine + line own-stream, all three
	// roles). For each, the birth-role path and the legacy-name path MUST agree
	// on a non-Unknown CounterKind.
	t.Run("legacy_descriptor_metrics", func(t *testing.T) {
		legacyNames := []string{
			"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",  // gross
			"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit", // net
			"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdDefectiveCount/63/Unit", // scrap
			"CPACK/SC/LINHAS/L5/TEXA/Admin/ProdConsumedCount/65/Unit",    // gross (2nd machine)
			"CPACK/SC/LINHAS/L5/TEXA/Admin/ProdProcessedCount/66/Unit",   // net
			"CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/51/Unit",         // gross (line own-stream)
			"CPACK/SC/LINHAS/L8/Admin/ProdProcessedCount/52/Unit",        // net
		}
		for _, name := range legacyNames {
			role, ok := producerRole(t, name)
			if !ok {
				t.Errorf("%s: producer declared no counter_role (birth.CounterMetricProps rejected it)", name)
				continue
			}
			kindFromRole := roleToCounterKind(role)
			kindFromName := isCounterMetricName(name)
			if kindFromRole == calc.CounterKindUnknown {
				t.Errorf("%s: role %q maps to Unknown kind (roleToCounterKind gap)", name, role)
			}
			if kindFromRole != kindFromName {
				t.Errorf("CUTOVER DRIFT for %s: birth-role path → %v (role=%q) but legacy-name path → %v — the two derivations disagree",
					name, kindFromRole, role, kindFromName)
			}
		}
	})

	// ── (2) Shared goldens — the post-cutover form ───────────────────────────
	// Every golden metric declares a role that routes (roleToCounterKind !=
	// Unknown), and the legacy parser is deliberately blind to the canonical
	// display names (§5) — which is precisely why the birth path is needed.
	t.Run("golden_fixtures", func(t *testing.T) {
		for _, fxName := range []string{"cpack-birth-example.json", "bisnago-birth-example.json"} {
			fx := loadBirthFixture(t, fxName)
			for _, dev := range fx.Devices {
				for _, m := range dev.Metrics {
					role, ok := birthbind.ParseRole(m.CounterRole)
					if !ok {
						t.Errorf("%s: metric %q declares invalid counter_role %q", fxName, m.Name, m.CounterRole)
						continue
					}
					if got := roleToCounterKind(role); got == calc.CounterKindUnknown {
						t.Errorf("%s: metric %q (role %q) does not route — roleToCounterKind → Unknown", fxName, m.Name, role)
					}
					// Canonical display names carry no legacy substring: the birth
					// path is the ONLY thing that can classify them.
					if got := isCounterMetricName(m.Name); got != calc.CounterKindUnknown {
						t.Errorf("%s: canonical name %q unexpectedly matched the legacy parser (→ %v); goldens should be display-only",
							fxName, m.Name, got)
					}
				}
			}
		}
	})

	// ── (3) evalCounter-level equivalence — byte-safe at the emission layer ───
	// Feed the SAME counter through the shared Calc core twice: once with the
	// legacy-name-derived kind, once with the birth-role-derived kind. The emitted
	// Metrics must be IDENTICAL. (evalCounter's kind arg only labels metrics —
	// Calc recomputes from the topic — so equality is guaranteed once the kinds
	// agree, which (1) proves. This locks that in as a regression guard: if
	// evalCounter ever starts branching on kind, this catches the divergence.)
	t.Run("evalCounter_emissions", func(t *testing.T) {
		const base = "CPACK/SC/LINHAS/L5/BREYER"
		name := base + "/Admin/ProdConsumedCount/61/Unit"

		kindFromName := isCounterMetricName(name)
		role, ok := producerRole(t, name)
		if !ok {
			t.Fatalf("producer declared no role for %s", name)
		}
		kindFromRole := roleToCounterKind(role)
		if kindFromName != kindFromRole {
			t.Fatalf("precondition: kinds disagree (%v vs %v)", kindFromName, kindFromRole)
		}

		seed := func(h calcHooks) {
			_ = h.state.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 90)
			_ = h.state.SetInt(base+"/Admin/ProdProcessedCount/61/Unit", 85)
			_ = h.state.SetInt(base+"/Admin/ProdDefectiveCount/61/Unit", 5)
			_ = h.state.SetFloat(base+"/Status/MachSpeed", 100.0)
		}
		ts := time.Unix(1700000000, 0)
		metric := sparkplug.ResolvedMetric{Name: name, Value: uint64(95)} // +5 delta

		hooksName := newTestCalcHooks(t)
		seed(hooksName)
		outName := hooksName.evalCounter(context.Background(), "cpack", kindFromName, metric, ts, testLogger())

		hooksRole := newTestCalcHooks(t)
		seed(hooksRole)
		outRole := hooksRole.evalCounter(context.Background(), "cpack", kindFromRole, metric, ts, testLogger())

		if len(outName) == 0 {
			t.Fatalf("legacy-name path emitted nothing — seeding/precondition wrong")
		}
		if !reflect.DeepEqual(outName, outRole) {
			t.Errorf("evalCounter emissions differ between name-kind and role-kind paths:\n name-path: %+v\n role-path: %+v", outName, outRole)
		}
	})
}

// ── Golden fixture loader (shared with the birthbind package's test) ─────────

type birthFixture struct {
	GroupID    string               `json:"group_id"`
	EdgeNodeID string               `json:"edge_node_id"`
	Devices    []birthFixtureDevice `json:"devices"`
}

type birthFixtureDevice struct {
	DeviceKey string               `json:"device_key"`
	Metrics   []birthFixtureMetric `json:"metrics"`
}

type birthFixtureMetric struct {
	Name        string `json:"name"`
	Alias       uint64 `json:"alias"`
	CounterRole string `json:"counter_role"`
}

// loadBirthFixture ascends from the test's working dir to find the shared golden
// under docs/reference/fixtures, so it works from the module dir or the repo root
// (same strategy as internal/birthbind's test).
func loadBirthFixture(t *testing.T, name string) birthFixture {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		cand := filepath.Join(dir, "docs", "reference", "fixtures", name)
		if b, err := os.ReadFile(cand); err == nil {
			var fx birthFixture
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
