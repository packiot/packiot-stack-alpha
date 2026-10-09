package handlers

import (
	"encoding/json"
	"testing"
	"time"
)

// Fixtures are real staging entries sampled 2026-07-01 to catch any
// future edge-api JSON drift.

func TestOrderCreatedStartedDecoding(t *testing.T) {
	fixture := `{
		"idArea": 4,
		"idSite": 3,
		"idOrder": 1782926738,
		"timestamp": "2026-07-02T04:05:10.340440+00:00",
		"idEquipment": 3,
		"idEnterprise": 2,
		"nmProductionOrder": "Zeta-Housing-M6",
		"productionOrderQuantity": 2608,
		"txtProductionOrderNotes": "ZetaWorks"
	}`
	var p OrderCreatedStartedPayload
	if err := json.Unmarshal([]byte(fixture), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDOrder != 1782926738 {
		t.Errorf("IDOrder: got %d, want 1782926738", p.IDOrder)
	}
	if p.NmProductionOrder != "Zeta-Housing-M6" {
		t.Errorf("NmProductionOrder: got %q", p.NmProductionOrder)
	}
	if p.ProductionOrderQuantity != 2608 {
		t.Errorf("ProductionOrderQuantity: got %d", p.ProductionOrderQuantity)
	}
	if _, err := time.Parse(time.RFC3339Nano, p.Timestamp); err != nil {
		t.Errorf("Timestamp %q not parseable as RFC3339Nano: %v", p.Timestamp, err)
	}
}

func TestOrderStoppedDecoding(t *testing.T) {
	fixture := `{
		"stopType": "pause",
		"timestamp": "2026-07-02T04:06:21.310634+00:00",
		"idEquipment": 5,
		"idEnterprise": 2,
		"idProductionOrder": 17533,
		"productionOrderQuantity": 0
	}`
	var p OrderStoppedPayload
	if err := json.Unmarshal([]byte(fixture), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.StopType != "pause" {
		t.Errorf("StopType: got %q, want pause", p.StopType)
	}
	if p.IDProductionOrder != 17533 {
		t.Errorf("IDProductionOrder: got %d, want 17533", p.IDProductionOrder)
	}
}
