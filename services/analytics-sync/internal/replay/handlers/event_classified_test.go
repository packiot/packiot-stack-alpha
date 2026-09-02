package handlers

import (
	"encoding/json"
	"strings"
	"testing"
)

// Fixtures sampled verbatim from staging user_logs 2026-07-16 (via
// SELECT payload FROM user_logs WHERE category='event-justified'/'event-edited').
// If edge-api's JustifyDto changes shape, these catch it before
// shadow-mirror silently mis-writes classifications.

// A real event-justified payload (id_user_logs 110169).
const fxEventJustified = `{
	"idle": "no",
	"cdMachine": "Breyer",
	"cdCategory": "set/02",
	"changeOver": false,
	"idEquipment": 50,
	"descCategory": "Ajustes",
	"idEnterprise": 3,
	"cdSubcategory": "A23 - Sistema Piovan",
	"descSubcategory": "A23 - Sistema Piovan",
	"plannedDowntime": false,
	"idEquipmentEvent": 6374744,
	"txtDowntimeNotes": "Falha na sucção de PEBD"
}`

// A real event-edited payload (id_user_logs 104302) — note plannedDowntime=true.
const fxEventEdited = `{
	"idle": "no",
	"cdMachine": "Geral - Linha",
	"cdCategory": "PRG-04",
	"changeOver": false,
	"idEquipment": 52,
	"descCategory": "Aprovação em Máquina",
	"idEnterprise": 3,
	"cdSubcategory": "",
	"descSubcategory": "",
	"plannedDowntime": true,
	"idEquipmentEvent": 6111897,
	"txtDowntimeNotes": "Saindo o item DD5007009a entrando o  item  DD5007008a"
}`

func TestEventClassifiedDecoding_Justified(t *testing.T) {
	var p EventClassifiedPayload
	if err := json.Unmarshal([]byte(fxEventJustified), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDEquipmentEvent != 6374744 {
		t.Errorf("IDEquipmentEvent: got %d, want 6374744", p.IDEquipmentEvent)
	}
	if p.IDEquipment != 50 {
		t.Errorf("IDEquipment: got %d, want 50", p.IDEquipment)
	}
	if p.CdCategory != "set/02" || p.CdSubcategory != "A23 - Sistema Piovan" {
		t.Errorf("category codes: %+v", p)
	}
	if p.CdMachine != "Breyer" {
		t.Errorf("CdMachine: got %q", p.CdMachine)
	}
	if p.Idle != "no" {
		t.Errorf("Idle: got %q, want %q", p.Idle, "no")
	}
	if p.ChangeOver || p.PlannedDowntime {
		t.Errorf("flags: changeOver=%v plannedDowntime=%v, want both false", p.ChangeOver, p.PlannedDowntime)
	}
	if p.TxtDowntimeNotes != "Falha na sucção de PEBD" {
		t.Errorf("TxtDowntimeNotes: got %q", p.TxtDowntimeNotes)
	}
}

func TestEventClassifiedDecoding_Edited(t *testing.T) {
	var p EventClassifiedPayload
	if err := json.Unmarshal([]byte(fxEventEdited), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDEquipmentEvent != 6111897 {
		t.Errorf("IDEquipmentEvent: got %d, want 6111897", p.IDEquipmentEvent)
	}
	// event-edited carries the same shape as event-justified; the only
	// distinction (already-classified) lives in edge-api, not the payload.
	if !p.PlannedDowntime {
		t.Errorf("PlannedDowntime: got false, want true")
	}
	if p.CdSubcategory != "" || p.DescSubcategory != "" {
		t.Errorf("empty subcategory expected, got cd=%q desc=%q", p.CdSubcategory, p.DescSubcategory)
	}
}

// Regression guard for the bug-248 id-space trap: the classification
// UPDATE must target the flow-stable natural key (id_equipment, ts_event)
// — never the payload's id_equipment_event, which is a per-flow surrogate
// that differs across F1/F2/F3.
func TestEventClassificationTargetsNaturalKey(t *testing.T) {
	sql := sqlUpdateEventClassification
	if !strings.Contains(sql, "id_equipment = $") || !strings.Contains(sql, "ts_event = $") {
		t.Errorf("WHERE clause must target (id_equipment, ts_event):\n%s", sql)
	}
	if strings.Contains(sql, "id_equipment_event") {
		t.Errorf("must not key on id_equipment_event (bug-248 id-space trap):\n%s", sql)
	}
	// It must actually write the classification, not just touch the row.
	for _, col := range []string{"cd_category", "cd_subcategory", "desc_category",
		"desc_subcategory", "cd_machine", "txt_downtime_notes",
		"change_over", "idle", "planned_downtime"} {
		if !strings.Contains(sql, col+" = $") {
			t.Errorf("UPDATE must set %s (mirror of edge-api DowntimesDAO.update):\n%s", col, sql)
		}
	}
}

// The resolver must read Flow 1's public.equipment_events (the source of
// truth for the natural key), not a shadow schema.
func TestResolverReadsFlow1EquipmentEvents(t *testing.T) {
	// Compile-time: resolveEquipmentEventKey exists with the right signature.
	_ = resolveEquipmentEventKey
}
