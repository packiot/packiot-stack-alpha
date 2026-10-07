package sparkplug

import (
	"context"
	"testing"
	"time"
)

func seeded() *Resolver {
	r := NewResolver(nil, time.Minute, time.Minute)
	r.SeedForTest("CPACK/SC/LINHAS/L5", &EquipmentInfo{IDEquipment: 47, IDEnterprise: 3})         // PackML says 47
	r.SeedForTest("CPACK/SC/LINHAS/L7", &EquipmentInfo{IDEquipment: 70, IDEnterprise: 3})         // switched tenant, unstamped
	r.SeedForTest("BISPHARMA/SP/LINHAS/L1/M1", &EquipmentInfo{IDEquipment: 500, IDEnterprise: 5}) // not switched
	r.SeedForTest("CPACK/SC/LINHAS/L5/Status", &EquipmentInfo{IDEquipment: 47, IDEnterprise: 3})
	r.SeedByIDForTest(48, &EquipmentInfo{IDEquipment: 48, IDEnterprise: 3, IDArea: 9}) // birth says 48
	r.SeedByIDForTest(90, &EquipmentInfo{IDEquipment: 90, IDEnterprise: 5})            // another tenant
	r.SeedByIDForTest(91, nil)                                                         // inactive / unknown
	return r
}

func TestApplyBirthBound_PerTenantSwitch(t *testing.T) {
	r := seeded()
	p, err := Parse([]byte(`{"timestamp":1,"id_enterprise":3,"metrics":[
	 {"name":"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/1/Unit","value":1,"id_equipment":48,"role":"counter.gross"},
	 {"name":"CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount/2/Unit","value":1,"id_equipment":90,"role":"counter.net"},
	 {"name":"CPACK/SC/LINHAS/L5/Admin/ProdDefectiveCount/3/Unit","value":1,"id_equipment":91,"role":"counter.scrap"},
	 {"name":"CPACK/SC/LINHAS/L7/Admin/ProdConsumedCount/4/Unit","value":1},
	 {"name":"CPACK/SC/LINHAS/L5/Status/StateCurrent","value":6}
	]}`))
	if err != nil {
		t.Fatal(err)
	}
	o, err := r.ApplyBirthBound(context.Background(), p, map[int]bool{3: true})
	if err != nil {
		t.Fatal(err)
	}
	if o.Bound != 1 || o.Quarantined != 3 {
		t.Fatalf("outcome = %+v, want 1 bound / 3 quarantined", o)
	}
	ctx := context.Background()
	// bound: the BIRTH identity wins over the PackML row (48, not 47)
	if info, _ := r.ResolveMetric(ctx, &p.Metrics[0]); info == nil || info.IDEquipment != 48 || info.IDArea != 9 {
		t.Errorf("bound metric resolved to %+v, want equipment 48 by id", info)
	}
	// quarantined: other-tenant id, unknown id, unstamped counter of a switched tenant
	for i := 1; i <= 3; i++ {
		if info, _ := r.ResolveMetric(ctx, &p.Metrics[i]); info != nil {
			t.Errorf("metric %d must be quarantined (skip), got %+v", i, info)
		}
	}
	// non-counter: still PackML (roles for state/speed are not declared at birth yet)
	if info, _ := r.ResolveMetric(ctx, &p.Metrics[4]); info == nil || info.IDEquipment != 47 {
		t.Errorf("state metric = %+v, want the PackML row (47)", info)
	}
}

func TestApplyBirthBound_OtherTenantsAndEmptySwitchUntouched(t *testing.T) {
	r := seeded()
	body := `{"timestamp":1,"id_enterprise":3,"metrics":[
	 {"name":"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/1/Unit","value":1,"id_equipment":48,"role":"counter.gross"},
	 {"name":"BISPHARMA/SP/LINHAS/L1/M1/Admin/ProdConsumedCount/1/Unit","value":1}]}`
	for _, sw := range []map[int]bool{nil, {5: true}} {
		p, _ := Parse([]byte(body))
		o, err := r.ApplyBirthBound(context.Background(), p, sw)
		if err != nil || o != (BirthBoundOutcome{}) && sw == nil {
			t.Fatalf("switch %v: outcome %+v err %v", sw, o, err)
		}
		// CPACK (3) is not switched in either case → PackML (47)
		if info, _ := r.ResolveMetric(context.Background(), &p.Metrics[0]); info == nil || info.IDEquipment != 47 {
			t.Errorf("switch %v: CPACK metric = %+v, want PackML 47", sw, info)
		}
	}
	// switch {5}: the unstamped BISPHARMA counter belongs to a switched tenant → quarantined
	p, _ := Parse([]byte(body))
	if o, _ := r.ApplyBirthBound(context.Background(), p, map[int]bool{5: true}); o.Quarantined != 1 {
		t.Errorf("unstamped counter of switched tenant 5: outcome %+v, want 1 quarantined", o)
	}
}
