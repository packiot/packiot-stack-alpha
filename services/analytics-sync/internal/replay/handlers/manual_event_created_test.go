package handlers

import (
	"encoding/json"
	"testing"
	"time"
)

// TestManualEventCreatedPayloadDecoding verifies the payload struct
// matches what real staging entries look like. If edge-api ever changes
// the JSON shape (new camelCase names, wrapper struct, whatever), this
// test catches it before shadow-mirror silently mis-writes rows.
//
// The fixture is one live payload sampled 2026-07-01 from staging via
// SELECT payload FROM user_logs WHERE category='manual-event-created'.
func TestManualEventCreatedPayloadDecoding(t *testing.T) {
	fixture := `{
		"tsEnd": "2026-07-02T00:17:23.000Z",
		"tsEvent": "2026-07-01T23:17:28.000Z",
		"duration": 3595,
		"cdMachine": "Sim-Machine-C",
		"cdCategory": "IDLE",
		"idEquipment": 5,
		"descCategory": "Idle / Waiting",
		"idEnterprise": 2,
		"cdSubcategory": "WAIT_OP",
		"descSubcategory": "Waiting for Operator",
		"txtDowntimeNotes": "Manual via NR by maria.operator"
	}`
	var p ManualEventCreatedPayload
	if err := json.Unmarshal([]byte(fixture), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDEquipment != 5 {
		t.Errorf("IDEquipment: got %d, want 5", p.IDEquipment)
	}
	if p.IDEnterprise != 2 {
		t.Errorf("IDEnterprise: got %d, want 2", p.IDEnterprise)
	}
	if p.Duration != 3595 {
		t.Errorf("Duration: got %d, want 3595", p.Duration)
	}
	if p.CdMachine != "Sim-Machine-C" {
		t.Errorf("CdMachine: got %q, want Sim-Machine-C", p.CdMachine)
	}
	if p.CdCategory != "IDLE" {
		t.Errorf("CdCategory: got %q, want IDLE", p.CdCategory)
	}
	if p.CdSubcategory != "WAIT_OP" {
		t.Errorf("CdSubcategory: got %q, want WAIT_OP", p.CdSubcategory)
	}
	// tsEvent parsing sanity — RFC3339 with millisecond precision.
	if _, err := time.Parse(time.RFC3339, p.TsEvent); err != nil {
		t.Errorf("TsEvent (%q) not parseable as RFC3339: %v", p.TsEvent, err)
	}
	if _, err := time.Parse(time.RFC3339, p.TsEnd); err != nil {
		t.Errorf("TsEnd (%q) not parseable as RFC3339: %v", p.TsEnd, err)
	}
}

// TestManualEventCreatedPayloadEmpty — Phase 2 handler must ErrSkip
// when required fields are missing (idEquipment=0 or tsEvent="").
// This test just documents the payload edge case; the handler itself
// enforces it (see ManualEventCreated).
func TestManualEventCreatedPayloadEmpty(t *testing.T) {
	var p ManualEventCreatedPayload
	if err := json.Unmarshal([]byte(`{}`), &p); err != nil {
		t.Fatalf("empty object should unmarshal to zero value: %v", err)
	}
	if p.IDEquipment != 0 {
		t.Errorf("IDEquipment: got %d, want 0", p.IDEquipment)
	}
}
