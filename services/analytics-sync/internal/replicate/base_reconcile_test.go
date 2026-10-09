package replicate

import (
	"strings"
	"testing"
	"time"
)

func TestPlanBaseMapsAndDrops(t *testing.T) {
	six, ten := 6, 10
	t0 := time.Date(2026, 10, 7, 16, 43, 0, 0, time.FixedZone("BRT", -3*3600))
	resolve := func(id int) (StagingEquip, bool) {
		switch id {
		case 106:
			return StagingEquip{IDEquipment: 83, IDEnterprise: 3}, true
		case 107:
			return StagingEquip{IDEquipment: 88, IDEnterprise: 3}, true
		}
		return StagingEquip{}, false
	}
	plan, unresolved, nostatus := planBase([]legacyBase{
		{LegacyEquip: 107, TsEvent: t0, Status: &six},
		{LegacyEquip: 106, TsEvent: t0.Add(time.Hour), Status: &ten},
		{LegacyEquip: 106, TsEvent: t0, Status: &six},
		{LegacyEquip: 999, TsEvent: t0, Status: &six}, // unresolved
		{LegacyEquip: 106, TsEvent: t0.Add(2 * time.Hour)},
	}, resolve)
	if unresolved != 1 || nostatus != 1 || len(plan) != 3 {
		t.Fatalf("plan=%+v unresolved=%d nostatus=%d", plan, unresolved, nostatus)
	}
	if plan[0].IDEquipment != 83 || !plan[0].TsEvent.Equal(t0) || plan[0].Status != 6 || plan[1].Status != 10 || plan[2].IDEquipment != 88 {
		t.Fatalf("plan not ordered/mapped: %+v", plan)
	}
	if plan[0].TsEvent.Location() != time.UTC {
		t.Fatalf("ts must be UTC: %v", plan[0].TsEvent)
	}
	if plan[0].ID != genEventID(t0.UTC(), 83) {
		t.Fatalf("id must follow the replay's genEventID: %d", plan[0].ID)
	}
}

// Both base-event writers (replay + reconciler) carry the ±1 s duplicate guard and
// the PLC-event shape (forced_creation_system=false), and the legacy fetch never
// copies operator-created rows.
func TestBaseEventWritersShareGuard(t *testing.T) {
	for name, sql := range map[string]string{"replay": sqlInsertEquipmentEvent, "reconcile": sqlBaseInsert} {
		if !strings.Contains(sql, baseNoNeighbour) {
			t.Errorf("%s insert lacks the ±1 s neighbour guard:\n%s", name, sql)
		}
		if !strings.Contains(sql, "false, now()") || !strings.Contains(sql, "ON CONFLICT (id_equipment, ts_event) DO NOTHING") {
			t.Errorf("%s insert must be an idempotent fcs=false PLC event:\n%s", name, sql)
		}
	}
	if !strings.Contains(sqlBaseLegacyFetch, "forced_creation_system IS NOT TRUE") {
		t.Errorf("legacy fetch must skip operator-created rows:\n%s", sqlBaseLegacyFetch)
	}
}
