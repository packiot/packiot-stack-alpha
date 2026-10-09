package handlers

import (
	"encoding/json"
	"testing"
	"time"
)

// Fixtures sampled from real staging entries 2026-07-01. If edge-api
// changes the JSON shape, these tests catch it before shadow-mirror
// mis-writes.

func TestOrderStartedDecoding(t *testing.T) {
	fx := `{"idArea":10,"idSite":6,"timestamp":"2026-07-02T03:03:30Z","idEquipment":49,"idEnterprise":3,"idProductionOrder":17496}`
	var p OrderStartedPayload
	if err := json.Unmarshal([]byte(fx), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDProductionOrder != 17496 {
		t.Errorf("IDProductionOrder: got %d", p.IDProductionOrder)
	}
	if _, err := time.Parse(time.RFC3339, p.Timestamp); err != nil {
		t.Errorf("Timestamp: %v", err)
	}
}

func TestOrderTimeChangedDecoding(t *testing.T) {
	fx := `{"start":"2026-07-02T03:51:09.475Z","idEquipment":3,"idProductionOrder":17527,"idProductionOrderRuntime":17517}`
	var p OrderTimeChangedPayload
	if err := json.Unmarshal([]byte(fx), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDProductionOrder != 17527 || p.IDProductionOrderRuntime != 17517 {
		t.Errorf("PO ids: %+v", p)
	}
}

func TestManualEventEditedDecoding(t *testing.T) {
	fx := `{"end":"2026-07-02T04:03:33.000Z","idle":false,"start":"2026-07-02T03:42:06.000Z","cdMachine":"Sim-Machine-A","cdCategory":"EQUIP_FAIL","changeOver":false,"idEquipment":3,"descCategory":"Equipment Failure","cdSubcategory":"MECH","descSubcategory":"Mechanical Failure","plannedDowntime":false,"idEquipmentEvent":62794,"txtDowntimeNotes":"Corrected via NR by ana.operator"}`
	var p ManualEventEditedPayload
	if err := json.Unmarshal([]byte(fx), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDEquipmentEvent != 62794 {
		t.Errorf("IDEquipmentEvent: got %d", p.IDEquipmentEvent)
	}
	if p.CdCategory != "EQUIP_FAIL" {
		t.Errorf("CdCategory: got %q", p.CdCategory)
	}
}

func TestEventSplittedDecoding(t *testing.T) {
	fx := `{"events":[{"idle":"No","note":"Split-A","type":"downtime","endTime":"2026-06-13T16:26:31.000Z","startTime":"2026-06-13T16:25:55.000Z","changeOver":true,"machineCode":"Sim-A","categoryCode":"CHANGEOVER","plannedDowntime":true}]}`
	var p EventSplittedPayload
	if err := json.Unmarshal([]byte(fx), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(p.Events) != 1 {
		t.Fatalf("Events count: got %d, want 1", len(p.Events))
	}
	e := p.Events[0]
	if e.Type != "downtime" || e.MachineCode != "Sim-A" || !e.ChangeOver {
		t.Errorf("event 0: %+v", e)
	}
}
