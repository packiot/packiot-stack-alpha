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
	sql, args, err := compileDataset(q, 42)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "h_piot_oee_score_with_teams") || !strings.Contains(sql, "LIMIT 10000") {
		t.Errorf("fn call or row cap missing: %s", sql)
	}
	// params order: ent, equipments, areas, sites, shifts, teams, from, to, grain, nav, shiftF, teamF
	if args[0] != 42 {
		t.Errorf("tenancy: args[0] = %v, want injected 42", args[0])
	}
	if args[1] != "{}" || args[3] != "{5,7}" || args[4] != "{2}" {
		t.Errorf("id-list literals wrong: %v", args)
	}
	if args[8] != "HOUR" {
		t.Errorf("time_grain not bound UPPERCASE: %v", args[8])
	}
	if args[10] != true || args[11] != false {
		t.Errorf("derived shift/team filtered flags wrong: %v %v", args[10], args[11])
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
		if _, _, err := compileDataset(bad, 42); err == nil {
			t.Errorf("compileDataset accepted invalid request: %+v", bad)
		}
	}
}

// Per-equipment overview functions take only an equipment id — the
// compiled SQL must carry the ownership guard, and the id is required.
func TestCompileDatasetEquipmentGuard(t *testing.T) {
	if _, _, err := compileDataset(datasetReq{Dataset: "overview-job-info"}, 42); err == nil {
		t.Error("per-equipment dataset compiled without an equipment filter")
	}
	sql, args, err := compileDataset(datasetReq{Dataset: "overview-job-info",
		Filters: map[string]json.RawMessage{"equipment": json.RawMessage(`7`)}}, 42)
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
	sql, args, err := compileDataset(datasetReq{Dataset: "enterprise-config"}, 42)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(sql, "api_key") || strings.Contains(sql, "SELECT *") {
		t.Errorf("enterprise-config must project explicit columns without api_key: %s", sql)
	}
	if !strings.Contains(sql, "id_enterprise = $1") || args[0] != 42 {
		t.Errorf("enterprise-config not tenancy-scoped: %s %v", sql, args)
	}
	usersSQL, _, err := compileDataset(datasetReq{Dataset: "users"}, 42)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"operator_pw_hash", "id_user_firebase", "SELECT *"} {
		if strings.Contains(usersSQL, secret) {
			t.Errorf("users dataset must not expose %q: %s", secret, usersSQL)
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
