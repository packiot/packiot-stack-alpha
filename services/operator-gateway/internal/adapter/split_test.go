package adapter

import (
	"net/http"
	"strings"
	"testing"
)

// Covers the /operator/split route: happy-path mapping (resolved id_equipment +
// cd_machine injected into every sub-event, edge path/eventType correct) and the
// fail-closed guards it shares with the rest of the surface (auth/scope via the
// generic pipeline, unresolved topic, and each required split field).

func validSplitBody() string {
	return `{
		"enterprise":4,
		"packml_topic":"GRANADO/JAPERI-UP1/MF5-OPACO/LINHA_D",
		"id_equipment_event":10500,
		"event_type":"downtime",
		"events":[
			{"start_time":"2026-07-09T10:00:00.000Z","end_time":"2026-07-09T10:20:00.000Z",
			 "category_code":"TOOL","desc_category":"Tooling","subcategory_code":"ACC","desc_subcategory":"Accumulator",
			 "note":"first half","idle":"no","change_over":false,"planned_dwt":false},
			{"start_time":"2026-07-09T10:20:00.000Z","end_time":"2026-07-09T10:40:00.000Z",
			 "category_code":"CLEAN","desc_category":"Cleaning","idle":"yes","change_over":true,"planned_dwt":false}
		],
		"user":"op1"
	}`
}

func TestSplit_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, reg := newTestServer(t, fp)
	rec := do(t, srv, "/operator/split", testKey, validSplitBody())
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/downtimes/split" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	got, ok := fp.last.body.(edgeSplit)
	if !ok {
		t.Fatalf("wrong body type: %T", fp.last.body)
	}
	if got.IDEquipmentEvent != 10500 || got.IDEquipment != resEquipment || got.EventType != "downtime" {
		t.Fatalf("header mismatch: %+v", got)
	}
	if len(got.Events) != 2 {
		t.Fatalf("want 2 sub-events, got %d", len(got.Events))
	}
	// Every sub-event's machineCode is the RESOLVED cd_machine, not caller-supplied.
	for i, e := range got.Events {
		if e.MachineCode != resCDMachine {
			t.Fatalf("events[%d].machineCode = %q, want resolved %q", i, e.MachineCode, resCDMachine)
		}
	}
	if got.Events[0].CategoryCode != "TOOL" || got.Events[1].Idle != "yes" || !got.Events[1].ChangeOver {
		t.Fatalf("sub-event field mismatch: %+v", got.Events)
	}
	if v := counterValue(t, reg, "split", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

func TestSplit_401_MissingKey(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	if rec := do(t, srv, "/operator/split", "", `{}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

func TestSplit_403_WrongEnterprise(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	body := `{"enterprise":99,"packml_topic":"GRANADO/L","id_equipment_event":1,"event_type":"downtime","events":[{"start_time":"t","category_code":"C","desc_category":"D","idle":"no","change_over":false,"planned_dwt":false}]}`
	if rec := do(t, srv, "/operator/split", testKey, body); rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", rec.Code)
	}
}

func TestSplit_422_UnknownTopic(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServerR(t, fp, &fakeResolver{err: ErrUnresolved})
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_equipment_event":1,"event_type":"downtime","events":[{"start_time":"t","category_code":"C","desc_category":"D","idle":"no","change_over":false,"planned_dwt":false}]}`
	if rec := do(t, srv, "/operator/split", testKey, body); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if fp.last != nil {
		t.Fatal("edge-api must NOT be called when the topic cannot be resolved")
	}
}

func TestSplit_422_MissingEventID(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","event_type":"downtime","events":[{"start_time":"t","category_code":"C","desc_category":"D","idle":"no","change_over":false,"planned_dwt":false}]}`
	rec := do(t, srv, "/operator/split", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "id_equipment_event") {
		t.Fatalf("422 should name id_equipment_event, got %s", rec.Body.String())
	}
}

func TestSplit_422_BadEventType(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_equipment_event":1,"event_type":"bogus","events":[{"start_time":"t","category_code":"C","desc_category":"D","idle":"no","change_over":false,"planned_dwt":false}]}`
	rec := do(t, srv, "/operator/split", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "event_type") {
		t.Fatalf("422 should name event_type, got %s", rec.Body.String())
	}
}

func TestSplit_422_EmptyEvents(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_equipment_event":1,"event_type":"downtime","events":[]}`
	rec := do(t, srv, "/operator/split", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "events") {
		t.Fatalf("422 should name events, got %s", rec.Body.String())
	}
}

func TestSplit_422_BadIdleInSubEvent(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	// Second sub-event has an invalid idle value edge-api would 400 on.
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_equipment_event":1,"event_type":"downtime","events":[
		{"start_time":"t","category_code":"C","desc_category":"D","idle":"no","change_over":false,"planned_dwt":false},
		{"start_time":"t2","category_code":"C","desc_category":"D","idle":"maybe","change_over":false,"planned_dwt":false}
	]}`
	rec := do(t, srv, "/operator/split", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "idle") {
		t.Fatalf("422 should name idle, got %s", rec.Body.String())
	}
	if fp.last != nil {
		t.Fatal("edge-api must NOT be called on unmapped input")
	}
}

func TestSplit_422_MissingBoolInSubEvent(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	// change_over absent (nil) must be distinguished from false and rejected.
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_equipment_event":1,"event_type":"downtime","events":[
		{"start_time":"t","category_code":"C","desc_category":"D","idle":"no","planned_dwt":false}
	]}`
	rec := do(t, srv, "/operator/split", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "change_over") {
		t.Fatalf("422 should name change_over, got %s", rec.Body.String())
	}
}
