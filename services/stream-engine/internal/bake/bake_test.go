package bake

import (
	"strings"
	"testing"
)

// ── CPACK-FROZEN GUARD ────────────────────────────────────────────────
// The production flip is gated on CPACK's (enterprise 3) bake numbers, so
// CPACK's queries MUST stay byte-identical to their pre-per-tenant form.
// These goldens are the surfaces' SQL captured BEFORE the per-tenant work
// (git-blame the original single-field struct). The gate tenant runs
// exactly these strings; any drift here means CPACK's signal moved.
var goldenGateSQL = map[string]string{
	"equipment_runtime_shift": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.equipment_runtime_shift l
	      JOIN shadow_go_port.equipment_runtime_shift g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_end < now() - interval '2 hours'
	       AND l.ts_value >= now() - interval '3 days') d`,
	"production_orders_runtime": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.production_orders_runtime l
	      JOIN shadow_go_port.production_orders_runtime g
	        ON l.id_equipment = g.id_equipment
	       AND lower(l.runtime_timerange) = lower(g.runtime_timerange)
	     WHERE upper(l.runtime_timerange) < now() - interval '2 hours'
	       AND lower(l.runtime_timerange) >= now() - interval '3 days') d`,
	"equipment_runtime_1hour": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 120) AS ok
	      FROM public.equipment_runtime_1hour l
	      JOIN shadow_go_port.equipment_runtime_1hour g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_value >= now() - interval '2 days'
	       AND l.ts_value < date_trunc('hour', now() - interval '2 hours')) d`,
	"equipment_runtime_1day": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 0.01*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))) AS ok
	      FROM public.equipment_runtime_1day l
	      JOIN shadow_go_port.equipment_runtime_1day g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_value >= now() - interval '4 days'
	       AND l.ts_value < date_trunc('day', now())) d`,
	"uns_equipment_current_month": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.02*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_month l
	      JOIN shadow_go_port.uns_equipment_current_month g USING (id_equipment)) d`,
	"uns_equipment_current_hour": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.05*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_hour l
	      JOIN shadow_go_port.uns_equipment_current_hour g USING (id_equipment)) d`,
	"uns_equipment_current_job": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (COALESCE(l.id_order::text,'') = COALESCE(g.id_order::text,'')) AS ok
	      FROM public.uns_equipment_current_job l
	      JOIN shadow_go_port.uns_equipment_current_job g USING (id_equipment)) d`,
	"customer_reports_shift_06": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT true AS ok FROM customer_reports.shift WHERE customer_id = 6) d`,
	"equipment_events_closed": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(extract(epoch FROM (l.ts_end - g.ts_end))) < 2) AS ok
	      FROM public.equipment_events l
	      JOIN shadow_go_port.equipment_events g
	        ON l.id_equipment = g.id_equipment AND l.ts_event = g.ts_event
	     WHERE l.ts_event >= now() - interval '2 days'
	       AND l.ts_end IS NOT NULL AND g.ts_end IS NOT NULL) d`,
	"uns_equipment_current_week": `
	SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 0.02*greatest(abs(COALESCE(l.gross_production,0)),abs(COALESCE(g.gross_production,0)))) AS ok
	      FROM public.uns_equipment_current_week l
	      JOIN shadow_go_port.uns_equipment_current_week g USING (id_equipment)) d`,
}

func surfaceByName(t *testing.T, name string) (sql, scoped, fixed string) {
	t.Helper()
	for _, s := range surfaces {
		if s.Name == name {
			return s.SQL, s.ScopedSQL, s.Fixed
		}
	}
	t.Fatalf("surface %q not found", name)
	return "", "", ""
}

// TestGateSQLByteIdentical pins every surface's frozen SQL. This is THE
// CPACK guard: the gate tenant executes surface.SQL verbatim, so byte
// equality here == CPACK's query text is unchanged.
func TestGateSQLByteIdentical(t *testing.T) {
	if len(goldenGateSQL) != len(surfaces) {
		t.Fatalf("golden count %d != surfaces count %d — a surface was added/removed without updating the CPACK guard", len(goldenGateSQL), len(surfaces))
	}
	for _, s := range surfaces {
		want, ok := goldenGateSQL[s.Name]
		if !ok {
			t.Errorf("surface %q has no CPACK golden — add it to goldenGateSQL", s.Name)
			continue
		}
		if s.SQL != want {
			t.Errorf("surface %q frozen SQL drifted from golden:\n got: %q\nwant: %q", s.Name, s.SQL, want)
		}
	}
}

// TestGateSQLUnscoped — the gate query must carry NO enterprise filter
// (that is what makes it byte-identical to the pre-per-tenant global
// query). If a scope leaked into surface.SQL, CPACK's numbers would move.
func TestGateSQLUnscoped(t *testing.T) {
	for _, s := range surfaces {
		if strings.Contains(s.SQL, "id_enterprise") || strings.Contains(s.SQL, "$1") {
			t.Errorf("surface %q frozen SQL is scoped (contains id_enterprise/$1) — CPACK must run the unscoped query", s.Name)
		}
	}
}

// TestDefaultConfigCPACKUnchanged — with BAKE_ENTERPRISE_IDS unset/"3",
// the emitted queries + labels for CPACK are identical to before: one run
// per per-tenant surface, label "3", verbatim SQL, no bind args; and the
// pool surface once under its fixed label. NO scoped SQL runs at all.
func TestDefaultConfigCPACKUnchanged(t *testing.T) {
	runs := planRuns([]int{3}) // config default "3"

	perTenant := 0
	for _, s := range surfaces {
		if s.ScopedSQL != "" {
			perTenant++
		}
	}
	// default: each per-tenant surface once (label 3) + each pool surface once.
	if len(runs) != len(surfaces) {
		t.Fatalf("default config expanded to %d runs, want %d (one per surface)", len(runs), len(surfaces))
	}

	seen := map[string]bool{}
	for _, r := range runs {
		seen[r.Surface] = true
		if r.Args != nil {
			t.Errorf("surface %q ran with bind args %v under default config — gate/pool must be verbatim", r.Surface, r.Args)
		}
		sql, _, fixed := surfaceByName(t, r.Surface)
		if fixed != "" { // pool/global surface
			if r.Label != fixed {
				t.Errorf("pool surface %q emitted under enterprise=%q, want fixed %q", r.Surface, r.Label, fixed)
			}
		} else { // per-tenant surface, gate tenant
			if r.Label != "3" {
				t.Errorf("gate surface %q emitted under enterprise=%q, want \"3\"", r.Surface, r.Label)
			}
			if r.SQL != sql {
				t.Errorf("gate surface %q did not run its verbatim SQL", r.Surface)
			}
		}
	}
	if len(seen) != len(surfaces) {
		t.Errorf("some surfaces missing from default plan: saw %d of %d", len(seen), len(surfaces))
	}
}

// TestTwoTenantPlan — with "3,4": CPACK (3) still frozen/verbatim, and
// Incoplast (4) runs the scoped variant carrying the enterprise label +
// bind arg. Every per-tenant surface appears for BOTH tenants; the pool
// surface stays a single series.
func TestTwoTenantPlan(t *testing.T) {
	runs := planRuns([]int{3, 4})

	type key struct{ surface, label string }
	got := map[key]plannedRun{}
	for _, r := range runs {
		k := key{r.Surface, r.Label}
		if _, dup := got[k]; dup {
			t.Errorf("duplicate run for %v", k)
		}
		got[k] = r
	}

	for _, s := range surfaces {
		if s.ScopedSQL == "" {
			// pool surface: exactly one series, under its fixed label, no per-tenant multiplication
			if _, ok := got[key{s.Name, "3"}]; ok {
				t.Errorf("pool surface %q must NOT be emitted under a bake-tenant label", s.Name)
			}
			if _, ok := got[key{s.Name, "4"}]; ok {
				t.Errorf("pool surface %q must NOT be emitted under a bake-tenant label", s.Name)
			}
			if _, ok := got[key{s.Name, s.Fixed}]; !ok {
				t.Errorf("pool surface %q missing under fixed label %q", s.Name, s.Fixed)
			}
			continue
		}
		// gate tenant 3: verbatim, no args
		g3, ok := got[key{s.Name, "3"}]
		if !ok {
			t.Errorf("surface %q missing for gate tenant 3", s.Name)
		} else {
			if g3.Args != nil {
				t.Errorf("gate surface %q (tenant 3) must run verbatim, got args %v", s.Name, g3.Args)
			}
			if g3.SQL != s.SQL {
				t.Errorf("gate surface %q (tenant 3) SQL not verbatim", s.Name)
			}
		}
		// tenant 4: scoped SQL, bind arg 4
		g4, ok := got[key{s.Name, "4"}]
		if !ok {
			t.Errorf("surface %q missing for tenant 4", s.Name)
		} else {
			if len(g4.Args) != 1 || g4.Args[0] != 4 {
				t.Errorf("scoped surface %q (tenant 4) must bind enterprise id 4, got %v", s.Name, g4.Args)
			}
			if g4.SQL != s.ScopedSQL {
				t.Errorf("scoped surface %q (tenant 4) did not run ScopedSQL", s.Name)
			}
			if !strings.Contains(g4.SQL, "id_enterprise = $1") {
				t.Errorf("scoped surface %q (tenant 4) missing enterprise filter", s.Name)
			}
		}
	}
}

// TestScopedPreservesWindowsAndTolerances — the scoped variant must add
// ONLY the enterprise filter: every time-window and tolerance clause from
// the frozen SQL must survive verbatim in ScopedSQL. Losing one silently
// changes what the tenant's parity signal measures.
func TestScopedPreservesWindowsAndTolerances(t *testing.T) {
	// distinctive window + tolerance fragments per surface
	clauses := map[string][]string{
		"equipment_runtime_shift":     {"interval '2 hours'", "interval '3 days'", "< 120", "0.01*greatest"},
		"production_orders_runtime":   {"interval '2 hours'", "interval '3 days'", "< 120", "0.01*greatest", "lower(l.runtime_timerange)"},
		"equipment_runtime_1hour":     {"interval '2 days'", "date_trunc('hour', now() - interval '2 hours')", "< 120", "0.01*greatest"},
		"equipment_runtime_1day":      {"interval '4 days'", "date_trunc('day', now())", "0.01*greatest"},
		"uns_equipment_current_month": {"0.02*greatest"},
		"uns_equipment_current_hour":  {"0.05*greatest"},
		"uns_equipment_current_job":   {"id_order::text"},
		"equipment_events_closed":     {"interval '2 days'", "< 2", "ts_end IS NOT NULL"},
		"uns_equipment_current_week":  {"0.02*greatest"},
	}
	for _, s := range surfaces {
		if s.ScopedSQL == "" {
			continue
		}
		must, ok := clauses[s.Name]
		if !ok {
			t.Errorf("surface %q has a ScopedSQL but no clause guard — add it", s.Name)
			continue
		}
		for _, c := range must {
			if !strings.Contains(s.ScopedSQL, c) {
				t.Errorf("scoped surface %q dropped clause %q", s.Name, c)
			}
			if !strings.Contains(s.SQL, c) {
				t.Errorf("frozen surface %q missing expected clause %q (guard is wrong)", s.Name, c)
			}
		}
		if !strings.Contains(s.ScopedSQL, "id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1)") {
			t.Errorf("scoped surface %q must scope via the equipments/id_enterprise idiom", s.Name)
		}
	}
}

// TestPoolSurfaceNotPerTenant documents + pins the one surface that is
// NOT enterprise-scopable: customer_reports_shift_06 is keyed by
// customer_id=6 (the sync06/shift06 POOL tenant = enterprise 6), so it
// stays a single global series under enterprise="6".
func TestPoolSurfaceNotPerTenant(t *testing.T) {
	sql, scoped, fixed := surfaceByName(t, "customer_reports_shift_06")
	if scoped != "" {
		t.Error("customer_reports_shift_06 must not be enterprise-scopable (ScopedSQL must be empty)")
	}
	if fixed != "6" {
		t.Errorf("customer_reports_shift_06 fixed label = %q, want \"6\" (customer_id=6 pool tenant)", fixed)
	}
	if !strings.Contains(sql, "customer_id = 6") {
		t.Error("customer_reports_shift_06 lost its customer_id=6 pool key")
	}
}

// TestScopedRunsWhenGateVaries — the gate is the FIRST configured id, so
// a single non-default tenant is treated as its own gate (verbatim). This
// pins the "first id = frozen gate" contract that keeps CPACK safe only
// when 3 leads the list.
func TestGateIsFirstConfigured(t *testing.T) {
	runs := planRuns([]int{4, 3}) // deliberately gate=4
	for _, r := range runs {
		if r.Surface == "equipment_runtime_shift" && r.Label == "4" {
			if r.Args != nil {
				t.Error("first configured enterprise (4 here) must be the verbatim gate")
			}
		}
		if r.Surface == "equipment_runtime_shift" && r.Label == "3" {
			if len(r.Args) != 1 || r.Args[0] != 3 {
				t.Error("non-first enterprise must run scoped with its bind arg")
			}
		}
	}
}
