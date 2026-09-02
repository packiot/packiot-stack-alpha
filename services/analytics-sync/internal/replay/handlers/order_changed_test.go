package handlers

import (
	"encoding/json"
	"testing"
	"time"
)

func TestOrderChangedDecoding(t *testing.T) {
	fx := `{
		"idArea": 3,
		"idSite": 3,
		"idOrder": 1782926737,
		"stopType": "finish",
		"timestamp": "2026-07-02T04:02:02.014140+00:00",
		"idEquipment": 5,
		"idEnterprise": 2,
		"shouldCreatePo": true,
		"shouldOpenNewPo": true,
		"idProductionOrder": null,
		"oldIdProductionOrder": 17465,
		"productionOrderQuantity": 4206,
		"oldProductionOrderProdFinal": 0
	}`
	var p OrderChangedPayload
	if err := json.Unmarshal([]byte(fx), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.OldIDProductionOrder != 17465 {
		t.Errorf("OldIDProductionOrder: got %d", p.OldIDProductionOrder)
	}
	if p.IDOrder != 1782926737 {
		t.Errorf("IDOrder: got %d", p.IDOrder)
	}
	if !p.ShouldCreatePo {
		t.Errorf("ShouldCreatePo should be true")
	}
	if p.StopType != "finish" {
		t.Errorf("StopType: got %q, want finish", p.StopType)
	}
	if _, err := time.Parse(time.RFC3339Nano, p.Timestamp); err != nil {
		t.Errorf("Timestamp %q not parseable: %v", p.Timestamp, err)
	}
}

func TestOrderChangedPauseVariant(t *testing.T) {
	// Pause variant — same shape but stopType="pause" + shouldCreatePo=false
	fx := `{"idArea":3,"idSite":3,"idOrder":0,"stopType":"pause",
		"timestamp":"2026-07-02T04:02:02Z","idEquipment":5,"idEnterprise":2,
		"shouldCreatePo":false,"shouldOpenNewPo":false,
		"oldIdProductionOrder":17465,"productionOrderQuantity":0,
		"oldProductionOrderProdFinal":150}`
	var p OrderChangedPayload
	if err := json.Unmarshal([]byte(fx), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.StopType != "pause" {
		t.Errorf("StopType: got %q", p.StopType)
	}
	if p.ShouldCreatePo {
		t.Errorf("ShouldCreatePo should be false")
	}
	if p.OldProductionOrderProdFinal != 150 {
		t.Errorf("OldProductionOrderProdFinal: got %d", p.OldProductionOrderProdFinal)
	}
}
