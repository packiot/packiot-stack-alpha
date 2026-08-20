package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// Registry-wide invariants — safety by construction, checked for every
// dataset so a new entry can't silently drop tenancy or the row cap.
func TestDatasetRegistryInvariants(t *testing.T) {
	for name, ds := range datasets {
		if len(ds.params) == 0 || ds.params[0].kind != pEnterprise {
			t.Errorf("%s: first param must be the injected enterprise id", name)
		}
		if !strings.Contains(ds.sql, "$1") {
			t.Errorf("%s: SQL does not bind the enterprise arg $1", name)
		}
		if strings.Contains(ds.sql, "api_key") {
			t.Errorf("%s: SQL references api_key — the tenancy secret must never transit this API", name)
		}
		if ds.windowed && ds.maxWindow <= 0 {
			t.Errorf("%s: windowed dataset without a window budget", name)
		}
		var hasFrom, hasTo bool
		for _, p := range ds.params {
			hasFrom = hasFrom || p.kind == pFrom
			hasTo = hasTo || p.kind == pTo
		}
		if ds.windowed != (hasFrom && hasTo) {
			t.Errorf("%s: windowed flag and window params disagree", name)
		}
		// params[i] ↔ $(i+1): the highest placeholder must exist and
		// nothing beyond it may appear.
		if n := len(ds.params); !strings.Contains(ds.sql, fmt.Sprintf("$%d", n)) {
			t.Errorf("%s: SQL is missing placeholder $%d for its last param", name, n)
		} else if strings.Contains(ds.sql, fmt.Sprintf("$%d", n+1)) {
			t.Errorf("%s: SQL has more placeholders than params", name)
		}
	}
}

// The catalog listing covers every root field from the front4 read
// census (2026-07-07 audit) that isn't already a fixed /v1/* route.
func TestDatasetCatalogCoversFront4Census(t *testing.T) {
	wantRoots := []string{
		// oee
		"h_piot_oee_score_with_teams", "h_piot_oee_score_full_3", "h_piot_oee_progress_new2",
		// live-uns-equipment
		"uns_equipment_current_job", "uns_equipment_current_metrics",
		"uns_equipment_current_day", "uns_equipment_current_shift", "uns_equipment_current_month",
		// mission-control
		"h_piot_get_mission_control_uns_3", "h_piot_get_mission_control_area_uns_2",
		"h_piot_get_mission_control_timeline",
		// overview-detail
		"h_piot_overview_i_get_job_info", "h_piot_overview_i_get_events", "h_piot_overview_i_get_events_3",
		"h_piot_overview_i_production_chart", "h_piot_overview_production_chart_v6",
		"h_piot_get_production_health", "h_piot_downtimes_duration_by_category",
		// downtimes-analytics
		"h_piot_get_downtimes_resumo", "h_piot_get_downtimes_per_category",
		"h_piot_get_downtimes_events", "h_piot_get_downtimes_events_2",
		// total-production / single-period / speed / flow
		"h_piot_total_production_teams_2", "h_piot_single_period_with_teams_3",
		"h_piot_single_period_with_teams_4", "h_piot_machine_speed", "h_piot_production_flow",
		// targets
		"h_piot_get_targets", "production_targets", "scrap_targets", "oee_targets",
		// enterprise-config
		"enterprises", "user_roles", "users",
		// front4→refdata migration (#58 Phases 2-3) net-new datasets
		"h_piot_home_uns",
		"h_piot_get_events_timeline_from_po", "h_piot_get_events_timeline_full_with_filter_3",
		"h_piot_production_orders_runtimes", "h_piot_production_orders_with_runtimes4",
		"v_entities_per_user_role", "v_menu_per_user_role",
		"equipment_runtime_1month", "equipment_runtime_1week", "equipment_runtime_1day",
		"sites", "downtime_reasons",
	}
	all := ""
	for _, ds := range datasets {
		all += ds.sql + "\n"
	}
	for _, root := range wantRoots {
		if !strings.Contains(all, root) {
			t.Errorf("census root %q not covered by any dataset", root)
		}
	}
	cat := datasetCatalog()
	if len(cat) != len(datasets) {
		t.Errorf("catalog lists %d datasets, registry has %d", len(cat), len(datasets))
	}
	for _, name := range []string{"oee-score-teams", "live-equipment-metrics", "mission-control",
		"overview-job-info", "downtimes-summary", "total-production", "single-period",
		"machine-speed", "production-flow", "targets", "enterprise-config"} {
		if _, ok := cat[name]; !ok {
			t.Errorf("catalog missing dataset %q", name)
		}
	}
	// Marshals cleanly — it's embedded in the /v1/catalog response.
	if _, err := json.Marshal(cat); err != nil {
		t.Errorf("catalog not JSON-serializable: %v", err)
	}
}

func TestCompileDatasetWindowed(t *testing.T) {
	win := &dsWindow{From: time.Now().Add(-7 * 24 * time.Hour), To: time.Now()}
	q := datasetReq{Dataset: "oee-score-teams", Window: win, Filters: map[string]json.RawMessage{
		"sites": json.RawMessage(`[5,7]`), "shifts": json.RawMessage(`[2]`),
		"time_grain": json.RawMessage(`"hour"`),
	}}
	sql, args, err := compileDataset(q, 42, callerRole{id: 55, present: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "h_piot_oee_score_with_teams") || !strings.Contains(sql, "LIMIT 10000") {
		t.Errorf("fn call or row cap missing: %s", sql)
	}
	// params order: ent, equipments, areas, sites, shifts, teams, from, to, grain, nav, shiftF
	// (11 args — the fn has no is_team_filtered on staging OR prod; see task #90).
	if args[0] != 42 {
		t.Errorf("tenancy: args[0] = %v, want injected 42", args[0])
	}
	if len(args) != 11 {
		t.Errorf("oee-score-teams binds %d args, want 11 (prod signature)", len(args))
	}
	if args[1] != "{}" || args[3] != "{5,7}" || args[4] != "{2}" {
		t.Errorf("id-list literals wrong: %v", args)
	}
	if args[8] != "HOUR" {
		t.Errorf("time_grain not bound UPPERCASE: %v", args[8])
	}
	if args[10] != true {
		t.Errorf("derived shift-filtered flag wrong: %v", args[10])
	}

	for _, bad := range []datasetReq{
		{Dataset: "nope", Window: win}, // unknown dataset
		{Dataset: "oee-score-teams"},   // missing required window
		{Dataset: "oee-score-teams", Window: &dsWindow{From: win.To, To: win.From}},                                                // inverted
		{Dataset: "oee-score-teams", Window: &dsWindow{From: time.Now().Add(-500 * 24 * time.Hour), To: time.Now()}},               // > budget
		{Dataset: "oee-score-teams", Window: win, Filters: map[string]json.RawMessage{"evil": json.RawMessage(`1`)}},               // unknown filter
		{Dataset: "oee-score-teams", Window: win, Filters: map[string]json.RawMessage{"time_grain": json.RawMessage(`"'; DROP"`)}}, // out of enum
		{Dataset: "mission-control", Window: win},                                                                                  // window on non-windowed dataset
	} {
		if _, _, err := compileDataset(bad, 42, callerRole{id: 55, present: true}); err == nil {
			t.Errorf("compileDataset accepted invalid request: %+v", bad)
		}
	}
}

// Per-equipment overview functions take only an equipment id — the
// compiled SQL must carry the ownership guard, and the id is required.
func TestCompileDatasetEquipmentGuard(t *testing.T) {
	if _, _, err := compileDataset(datasetReq{Dataset: "overview-job-info"}, 42, callerRole{id: 55, present: true}); err == nil {
		t.Error("per-equipment dataset compiled without an equipment filter")
	}
	sql, args, err := compileDataset(datasetReq{Dataset: "overview-job-info",
		Filters: map[string]json.RawMessage{"equipment": json.RawMessage(`7`)}}, 42, callerRole{id: 55, present: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "e.id_enterprise = $1") || !strings.Contains(sql, "e.id_equipment = $2") {
		t.Errorf("ownership guard missing: %s", sql)
	}
	if args[0] != 42 || args[1] != 7 {
		t.Errorf("guard args wrong: %v", args)
	}
}

// enterprises.api_key is the tenancy secret; users carries credential
// columns. Neither may be selectable through any dataset.
func TestEnterpriseConfigExcludesSecrets(t *testing.T) {
	sql, args, err := compileDataset(datasetReq{Dataset: "enterprise-config"}, 42, callerRole{id: 55, present: true})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(sql, "api_key") || strings.Contains(sql, "SELECT *") {
		t.Errorf("enterprise-config must project explicit columns without api_key: %s", sql)
	}
	if !strings.Contains(sql, "id_enterprise = $1") || args[0] != 42 {
		t.Errorf("enterprise-config not tenancy-scoped: %s %v", sql, args)
	}
	usersSQL, _, err := compileDataset(datasetReq{Dataset: "users"}, 42, callerRole{id: 55, present: true})
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"operator_pw_hash", "id_user_firebase", "SELECT *"} {
		if strings.Contains(usersSQL, secret) {
			t.Errorf("users dataset must not expose %q: %s", secret, usersSQL)
		}
	}
}

// ── front4→refdata migration datasets (#58 Phases 2-3) ───────────────────
//
// These assert the SHAPE contract of the 13-read gap: the Group-A functions
// bind the tenant at $1 and self-scope; the Group-B PO function is fenced by
// an outer WHERE id_enterprise = $1; the per-role bootstrap views project the
// api_key-bearing `enterprise` jsonb OUT; and the per-equipment settings/
// overview reads carry the ownership arg at $2.

func TestHomeUnsBindsTenantAtDollarOne(t *testing.T) {
	sql, args, err := compileDataset(datasetReq{Dataset: "home-uns"}, 42, callerRole{id: 55, present: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "h_piot_home_uns($1)") || args[0] != 42 {
		t.Errorf("home-uns must call the function with the injected tenant at $1: %s %v", sql, args)
	}
}

// events-timeline-from-po is Group B: the function has NO enterprise arg, so
// the tenant fence MUST be the outer WHERE id_enterprise = $1, with the PO id
// at $2. Without that wrapper a caller could probe other tenants' PO ids.
func TestEventsTimelineFromPOIsFenced(t *testing.T) {
	if _, _, err := compileDataset(datasetReq{Dataset: "events-timeline-from-po"}, 42, callerRole{id: 55, present: true}); err == nil {
		t.Error("events-timeline-from-po compiled without the required production_order filter")
	}
	sql, args, err := compileDataset(datasetReq{Dataset: "events-timeline-from-po",
		Filters: map[string]json.RawMessage{"production_order": json.RawMessage(`915`)}}, 42, callerRole{id: 55, present: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "WHERE id_enterprise = $1") {
		t.Errorf("events-timeline-from-po must fence the tenant with an outer WHERE id_enterprise = $1: %s", sql)
	}
	if !strings.Contains(sql, "h_piot_get_events_timeline_from_po($2)") {
		t.Errorf("events-timeline-from-po must pass the PO id at $2 (client), tenant at $1: %s", sql)
	}
	if args[0] != 42 || args[1] != 915 {
		t.Errorf("events-timeline-from-po args wrong: %v", args)
	}
}

// The windowed migration functions (Group A) take the tenant at $1 and the
// window as [tsstart, tsend]; the id-filter args are '{}' when absent.
func TestWindowedMigrationFunctionsBindTenantAndWindow(t *testing.T) {
	win := &dsWindow{From: time.Now().Add(-30 * 24 * time.Hour), To: time.Now()}
	for _, name := range []string{"events-timeline-full", "production-orders-runtimes", "production-orders-with-runtimes"} {
		sql, args, err := compileDataset(datasetReq{Dataset: name, Window: win}, 42, callerRole{id: 55, present: true})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if args[0] != 42 {
			t.Errorf("%s: tenant must be $1, got %v", name, args[0])
		}
		if !strings.Contains(sql, "LIMIT 10000") {
			t.Errorf("%s: row cap missing", name)
		}
		// window bounds must be bound as timestamps, never absent
		var sawFrom, sawTo bool
		for _, a := range args {
			if tv, ok := a.(time.Time); ok {
				sawFrom = sawFrom || tv.Equal(win.From)
				sawTo = sawTo || tv.Equal(win.To)
			}
		}
		if !sawFrom || !sawTo {
			t.Errorf("%s: window bounds not bound: %v", name, args)
		}
	}
	// events-timeline-full pins the optional _id_production_order to a literal
	// NULL so the window binds at $6/$7 — assert the NULL literal is present and
	// there is no $8 (7 params).
	sql, _, _ := compileDataset(datasetReq{Dataset: "events-timeline-full", Window: win}, 42, callerRole{id: 55, present: true})
	if !strings.Contains(sql, ",NULL,$6,$7)") {
		t.Errorf("events-timeline-full must pin _id_production_order to NULL: %s", sql)
	}
}

// The two bootstrap role views must project the api_key-bearing `enterprise`
// jsonb column OUT: v_entities_per_user_role.enterprise embeds enterprise
// config incl. api_key, so a SELECT * (or selecting that column) would re-leak
// the very secret this migration removes from the browser.
func TestBootstrapRoleViewsDoNotLeakEnterpriseJSONB(t *testing.T) {
	sql, args, err := compileDataset(datasetReq{Dataset: "entities-per-user-role"}, 42, callerRole{id: 55, present: true})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(sql, "SELECT *") {
		t.Errorf("entities-per-user-role must use an explicit projection, not SELECT *: %s", sql)
	}
	// the bare `enterprise` jsonb column must not be selected (id_enterprise is
	// fine; the leak vector is the standalone `enterprise` blob).
	if strings.Contains(sql, "nm_user_role,\n\t\t\tenterprise") || strings.Contains(sql, ", enterprise,") || strings.Contains(sql, ", enterprise ") {
		t.Errorf("entities-per-user-role selects the api_key-bearing `enterprise` jsonb: %s", sql)
	}
	if !strings.Contains(sql, "id_enterprise = $1") || args[0] != 42 {
		t.Errorf("entities-per-user-role not tenant-scoped: %s %v", sql, args)
	}
}

// The per-equipment settings/overview migration reads carry the ownership arg
// at $2 (tenant at $1) — same shape as the overview-detail group.
func TestPerEquipmentMigrationReadsRequireEquipmentAtDollarTwo(t *testing.T) {
	for _, name := range []string{"equipment-downtime-reasons", "site-by-equipment",
		"custom-target-month", "custom-target-week", "custom-target-day"} {
		if _, _, err := compileDataset(datasetReq{Dataset: name}, 42, callerRole{id: 55, present: true}); err == nil {
			t.Errorf("%s compiled without the required equipment filter", name)
		}
		sql, args, err := compileDataset(datasetReq{Dataset: name,
			Filters: map[string]json.RawMessage{"equipment": json.RawMessage(`7`)}}, 42, callerRole{id: 55, present: true})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if args[0] != 42 || args[1] != 7 {
			t.Errorf("%s: tenant must be $1, equipment $2; got %v", name, args)
		}
		if !strings.Contains(sql, "$1") || !strings.Contains(sql, "$2") {
			t.Errorf("%s: must bind $1 (tenant) and $2 (equipment): %s", name, sql)
		}
	}
}

func TestPgIntArray(t *testing.T) {
	if got := pgIntArray(nil); got != "{}" {
		t.Errorf("empty: %q", got)
	}
	if got := pgIntArray([]int{1, 22, 333}); got != "{1,22,333}" {
		t.Errorf("literal: %q", got)
	}
}

// TestSoftDeletedEntitiesAreFiltered locks in the soft-delete correctness fix
// (task #54): any dataset that READS an entity/dimension table (equipments,
// sites, enterprises, users) — either as its primary FROM (lists/metadata/counts)
// or as a tenancy/ownership JOIN — must fence the entity side on `active`, so a
// soft-deleted equipment/site/enterprise/user never surfaces in front4's lists,
// metadata, or counts. The predicate must hold on BOTH flows (F1 packiot and F3
// packiot_analytics); `active` was verified live to exist on all five entity tables
// in both DBs (2026-07-22). Fact tables (equipment_values/events, the
// equipment_runtime_*/uns_* snapshots) have NO active column and must NOT be
// filtered — those datasets fence only their JOINed equipments/sites alias.
func TestSoftDeletedEntitiesAreFiltered(t *testing.T) {
	// Datasets whose SQL must contain an entity-side `active` predicate. Grouped
	// by how the entity is read; every one is checked on both flows.
	wantActive := []string{
		// primary FROM an entity table (lists / metadata / counts) — the leak:
		"equipment-info", "equipments-list", "equipment-downtime-reasons",
		"equipments-events-column-flag", "site-by-equipment", "enterprise-config", "users",
		// entity JOINed/EXISTS as a tenancy or ownership fence (fence the entity,
		// NOT the fact table it is joined to):
		"oee-by-month", "current-shift", "equipment-runtime-1day",
		"custom-target-month", "custom-target-week", "custom-target-day",
		"overview-takt", "overview-scrap-rate",
		// liveUNS-generated (JOIN equipments for the tenant fence):
		"live-equipment-job", "live-equipment-day", "live-equipment-shift", "live-equipment-month",
		// perEquipment-generated (EXISTS equipments ownership guard):
		"overview-job-info", "overview-events", "overview-events-legacy",
		"overview-production-chart", "overview-production-chart-legacy",
		"overview-production-chart-base", "overview-production-health",
		"overview-downtimes-by-category",
	}
	for _, name := range wantActive {
		ds, ok := datasets[name]
		if !ok {
			t.Errorf("%s: not in the dataset registry (renamed/removed?)", name)
			continue
		}
		for _, f := range []flow{flowF1, flowF3} {
			sql := ds.activeSQL(f)
			// accept either `.active` (NOT NULL tables) or `active IS NOT FALSE`
			// (the nullable enterprises/users columns — NULL means legacy/visible).
			if !strings.Contains(sql, "active") {
				t.Errorf("%s (flow %s): missing the soft-delete `active` filter — a deleted entity would leak: %s", name, f, sql)
			}
		}
	}

	// Guard the intentional EXCLUSIONS so a future edit that "fixes" them trips
	// this test and forces a conscious decision (they are NOT bugs):
	//   - production-orders-rich / shifts: primary FROM is a FACT/definition table
	//     (production_orders / shifts); equipments/sites/areas appear only as
	//     LEFT-JOIN name enrichment, so an active predicate would over-filter and
	//     DROP valid rows. The equipment set front4 passes is already fenced
	//     upstream by equipments-list.
	//   - live-equipment-metrics: reads uns_equipment_current_metrics directly
	//     (it carries its own id_enterprise, so no equipments JOIN exists to
	//     fence); closing it would require restructuring into an EXISTS, out of
	//     scope for this predicate-only correctness fix. Tracked as a residual.
	for _, name := range []string{"production-orders-rich", "shifts", "live-equipment-metrics"} {
		if _, ok := datasets[name]; !ok {
			t.Errorf("%s: excluded dataset no longer exists — revisit the exclusion list", name)
		}
	}
}
