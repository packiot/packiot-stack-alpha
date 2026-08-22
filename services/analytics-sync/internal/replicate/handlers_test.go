package replicate

import (
	"encoding/json"
	"strings"
	"testing"
)

// Every PO lifecycle write must target the natural key (id_enterprise,
// id_order) — never the legacy surrogate id_production_order, which lives
// in a different id space than the staging rows (bug-248 discipline,
// doubly so across instances).
func TestPOWritesTargetNaturalKey(t *testing.T) {
	updates := map[string]string{
		"sqlUpdatePOStart":   sqlUpdatePOStart,
		"sqlUpdatePOStop":    sqlUpdatePOStop,
		"sqlUpdatePOTsStart": sqlUpdatePOTsStart,
		"sqlUpdatePORecalc":  sqlUpdatePORecalc,
		"sqlClosePOChanged":  sqlClosePOChanged,
	}
	for name, sql := range updates {
		if !strings.Contains(sql, "id_enterprise = $") || !strings.Contains(sql, "id_order = $") {
			t.Errorf("%s: must key on (id_enterprise, id_order):\n%s", name, sql)
		}
		if strings.Contains(sql, "id_production_order = ") {
			t.Errorf("%s: must not key on the legacy surrogate id_production_order:\n%s", name, sql)
		}
	}
	inserts := map[string]string{"sqlInsertPOAvailable": sqlInsertPOAvailable, "sqlInsertPORunning": sqlInsertPORunning}
	for name, sql := range inserts {
		if !strings.Contains(sql, "ON CONFLICT (id_enterprise, id_order) DO NOTHING") {
			t.Errorf("%s: must be idempotent on (id_enterprise, id_order):\n%s", name, sql)
		}
	}
}

// The staging equipment_events_man PK is a serial IDENTITY — the insert must
// NOT carry id_equipment_event (copying the legacy serial would collide with
// staging's sequence). Idempotency comes from the ts_event unique key.
func TestManualInsertOmitsSerialAndIsIdempotent(t *testing.T) {
	if strings.Contains(sqlInsertManualEvent, "id_equipment_event") {
		t.Errorf("sqlInsertManualEvent must not set id_equipment_event (staging serial):\n%s", sqlInsertManualEvent)
	}
	if !strings.Contains(sqlInsertManualEvent, "ON CONFLICT (id_equipment, ts_event) DO NOTHING") {
		t.Errorf("sqlInsertManualEvent must be idempotent on ts_event:\n%s", sqlInsertManualEvent)
	}
}

func TestEquipmentEventIdempotentOnNaturalKey(t *testing.T) {
	if !strings.Contains(sqlInsertEquipmentEvent, "ON CONFLICT (id_equipment, ts_event) DO NOTHING") {
		t.Errorf("sqlInsertEquipmentEvent must be idempotent on (id_equipment, ts_event):\n%s", sqlInsertEquipmentEvent)
	}
	if !strings.Contains(sqlUpdateEventClassification, "id_equipment = $") || !strings.Contains(sqlUpdateEventClassification, "ts_event = $") {
		t.Errorf("event classification must key on (id_equipment, ts_event):\n%s", sqlUpdateEventClassification)
	}
}

// Legacy payloads mix number and quoted-string numerics in the same field.
func TestFlexInt64ParsesLegacyForms(t *testing.T) {
	var p struct {
		A flexInt64 `json:"a"`
		B flexInt64 `json:"b"`
		C flexInt64 `json:"c"`
		D flexInt64 `json:"d"`
	}
	if err := json.Unmarshal([]byte(`{"a":"895241","b":895641,"c":"56602","d":null}`), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.A != 895241 || p.B != 895641 || p.C != 56602 || p.D != 0 {
		t.Errorf("flexInt64 mismatch: %+v", p)
	}
}

// Real order-changed payload sampled from legacy (numbers-as-strings).
func TestOrderChangedDecodesLegacyPayload(t *testing.T) {
	raw := `{"idArea":53,"idSite":1,"idOrder":895641,"stopType":"finish",
	  "timestamp":"2026-08-21T17:36:00-03:00","idEquipment":556,"idEnterprise":1,
	  "shouldCreatePo":false,"shouldOpenNewPo":true,"idProductionOrder":1681207,
	  "oldIdProductionOrder":1681206,"productionOrderQuantity":18000,
	  "oldProductionOrderProdFinal":"56602"}`
	var p orderChangedPayload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.OldIDProductionOrder != 1681206 || p.IDEquipment != 556 || p.OldProductionOrderProdFinal != 56602 {
		t.Errorf("decoded wrong: %+v", p)
	}
}

// downtime-event-created carries epoch-ms timestamps and legacy idEquipment.
func TestDowntimeEventDecodesEpochMillis(t *testing.T) {
	raw := `{"events":[{"topic":"C-PACK/SC/LINHAS/L5/TEXA/Status/StateCurrent","status":6,"timestamp":1787345520000,"idEquipment":65}]}`
	var p downtimeEventCreatedPayload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(p.Events) != 1 || p.Events[0].IDEquipment != 65 || p.Events[0].Timestamp != 1787345520000 || *p.Events[0].Status != 6 {
		t.Errorf("decoded wrong: %+v", p)
	}
}
