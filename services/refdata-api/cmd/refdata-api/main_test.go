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
		"h_piot_get_events_timeline3_with_event_id",
		"h_piot_get_equipment_pending_downtime_with_event_id",
		"piot_get_shift_hours_by_packml_topic_2",
		"piot_get_shift_hours_by_enterprise_packml_topic_2",
		"piot_get_day_week_begin_by_packml_topic",
		"v_operator_po_list_setup_4",
		"v_operator_po_details_3",
		"v_operator_entities_2",
		"v_entities_per_user_role_operator",
		"language_packs",
		"packml_register", // downtime-reasons join
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
	if len(endpoints) != 11 {
		t.Errorf("expected 11 endpoints, got %d", len(endpoints))
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
	if _, err := topicEnterpriseArg(httptest.NewRequest("GET", "/v1/x?topic=T&enterprise=abc", nil)); err == nil {
		t.Error("topicEnterpriseArg: want error on non-integer enterprise")
	}
	if args, err := topicEnterpriseArg(httptest.NewRequest("GET", "/v1/x?topic=T&enterprise=3", nil)); err != nil || args[1] != 3 {
		t.Errorf("topicEnterpriseArg: %v %v", args, err)
	}
}
