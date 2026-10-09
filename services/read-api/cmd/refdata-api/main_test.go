package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

// The endpoint table IS the Hasura-replacement contract — every root
// field from the query-log enumeration must be present, and every SQL
// must reference the LIVE view generation (the version-suffixed ones).
func TestContractCoverage(t *testing.T) {
	wantRoots := []string{
		"serving.events_timeline",
		"serving.pending_downtime",
		"piot_get_shift_hours_by_packml_topic_2",
		"piot_get_shift_hours_by_enterprise_packml_topic_2",
		"piot_get_day_week_begin_by_packml_topic",
		"v_operator_po_list_setup_4",
		"v_operator_po_details_3",
		"v_operator_entities_2",
		"v_entities_per_user_role_operator",
		"language_packs",
		"packml_register", // downtime-reasons join
		// ADR-0061 P3 /v2 operator routes (id-based siblings; v1 unchanged)
		"serving.events_timeline_by_equipment",
		"serving.pending_downtime_by_equipment",
		"serving.downtime_reasons_by_equipment",
		"serving.operator_po_list_by_equipment",
	}
	all := ""
	for _, ep := range endpoints {
		all += ep.sql + "\n"
	}
	for _, root := range wantRoots {
		if !strings.Contains(all, root) {
			t.Errorf("contract root %q not covered by any endpoint", root)
		}
	}
	if len(endpoints) != 15 { // 11 v1 + 4 ADR-0061 /v2
		t.Errorf("expected 15 endpoints, got %d", len(endpoints))
	}
}

func TestEquipmentIDsArg(t *testing.T) {
	a, err := equipmentIDsArg(httptest.NewRequest("GET", "/v2/x?equipment=47,%2053", nil))
	if err != nil || len(a) != 1 {
		t.Fatalf("equipmentIDsArg: %v %v", a, err)
	}
	if got := a[0].([]int32); len(got) != 2 || got[0] != 47 || got[1] != 53 {
		t.Errorf("parsed ids = %v, want [47 53]", got)
	}
	for _, bad := range []string{"", "?equipment=", "?equipment=1,x", "?equipment=0", "?equipment=-3", "?equipment=CPACK/SC/L5"} {
		if _, err := equipmentIDsArg(httptest.NewRequest("GET", "/v2/x"+bad, nil)); err == nil {
			t.Errorf("equipmentIDsArg(%q): want error", bad)
		}
	}
	many := strings.Repeat("1,", maxEquipmentIDs) + "1"
	if _, err := equipmentIDsArg(httptest.NewRequest("GET", "/v2/x?equipment="+many, nil)); err == nil {
		t.Error("equipmentIDsArg: want error above the id cap")
	}
}

func TestArgParsers(t *testing.T) {
	r := httptest.NewRequest("GET", "/v1/events-timeline?topics=A/B,C/D", nil)
	args, err := topicsArg(r)
	if err != nil || len(args) != 1 {
		t.Fatalf("topicsArg: %v %v", args, err)
	}
	if got := args[0].([]string); len(got) != 2 || got[0] != "A/B" {
		t.Errorf("topicsArg split: %v", got)
	}
	if _, err := topicsArg(httptest.NewRequest("GET", "/v1/x", nil)); err == nil {
		t.Error("topicsArg: want error on missing param")
	}
	// topicArg parses a single ?topic= (client filter, binds $2 — the tenant
	// is $1 from the key).
	a, err := topicArg(httptest.NewRequest("GET", "/v1/shift-hours?topic=T", nil))
	if err != nil || len(a) != 1 || a[0] != "T" {
		t.Errorf("topicArg: %v %v", a, err)
	}
	if _, err := topicArg(httptest.NewRequest("GET", "/v1/x", nil)); err == nil {
		t.Error("topicArg: want error on missing param")
	}
	// ADR-0027 §4: the client can no longer name a tenant — the ?enterprise=
	// parser (topicEnterpriseArg) is gone. The route now scopes to the key's
	// customer_id, verified by the isolation gate (tenancy_isolation_test.go).
}

// /v1/downtime-reasons must admit a LINE's own register row. A line's row has
// id_unit NULL (id_unit = id_equipment holds for machines only); the machine-only
// join dropped every line, so the operator — which asks for its line topic and
// prefers that row — got a member's empty tree on CPACK (2026-09-30).
func TestDowntimeReasonsRouteAdmitsLineTopics(t *testing.T) {
	for _, ep := range endpoints {
		if ep.path != "/v1/downtime-reasons" {
			continue
		}
		sql := strings.Join(strings.Fields(ep.sql), " ")
		if !strings.Contains(sql, "p.id_unit IS NULL AND e.tp_equipment = 3") {
			t.Errorf("downtime-reasons no longer admits line register rows:\n%s", sql)
		}
		return
	}
	t.Fatal("/v1/downtime-reasons route not found")
}
