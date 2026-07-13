package writers

import (
	"strings"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// ADR-0014 fold fidelity: with the resolver enabled, every equipment_values
// UPSERT must carry the three shift-fill columns folded straight into the
// INSERT (replacing the removed BuildShiftFill companion UPDATE), and the
// ON CONFLICT clause must keep-existing-else-fill via
// COALESCE(equipment_values.col, EXCLUDED.col). ts_value_production must reuse
// the ts_value bind ($1) for the session-tz date cast — byte-for-byte what
// piot_set_shift_on_equipment_values() did.
func TestShiftFoldFoldedIntoUpsert(t *testing.T) {
	ts := time.UnixMilli(1_700_000_000_000).Truncate(time.Second).UTC()
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 2, IDArea: 3, IDEquipment: 42}
	idShift, idShiftHour := 7, 9

	// Every CanWrite builder must fold the shift columns identically.
	builders := map[string]*Query{
		"processed": buildProcessed(ts, info, 1, 5, nil, nil, nil, ts.UnixMilli(), "public", true, &idShift, &idShiftHour),
		"consumed":  buildConsumed(ts, info, 1, 5, nil, nil, nil, ts.UnixMilli(), "public", true, &idShift, &idShiftHour),
		"defective": buildDefective(ts, info, 1, 5, nil, nil, ts.UnixMilli(), "public", true, &idShift, &idShiftHour),
		"state":     buildState(ts, info, 1, 5, nil, ts.UnixMilli(), "public", true, &idShift, &idShiftHour),
		"mode":      buildMode(ts, info, 1, 5, nil, nil, ts.UnixMilli(), "public", true, &idShift, &idShiftHour),
	}

	wantFrags := []string{
		"id_shift, id_shift_hour, ts_value_production",
		"($1)::date",
		"id_shift            = COALESCE(equipment_values.id_shift, EXCLUDED.id_shift)",
		"id_shift_hour       = COALESCE(equipment_values.id_shift_hour, EXCLUDED.id_shift_hour)",
		"ts_value_production = COALESCE(equipment_values.ts_value_production, EXCLUDED.ts_value_production)",
	}
	for name, q := range builders {
		for _, frag := range wantFrags {
			if !strings.Contains(q.SQL, frag) {
				t.Errorf("%s: folded UPSERT missing %q\nSQL:\n%s", name, frag, q.SQL)
			}
		}
		// The two shift-id binds append after the builder's own args; the
		// last two must be the resolved shift ids (pointers).
		if n := len(q.Args); n < 2 {
			t.Fatalf("%s: expected shift args appended, got %d args", name, n)
		}
		gotShift, ok1 := q.Args[len(q.Args)-2].(*int)
		gotHour, ok2 := q.Args[len(q.Args)-1].(*int)
		if !ok1 || !ok2 || gotShift == nil || gotHour == nil || *gotShift != idShift || *gotHour != idShiftHour {
			t.Errorf("%s: shift binds not appended in order (got %v,%v)", name, q.Args[len(q.Args)-2], q.Args[len(q.Args)-1])
		}
	}
}

// With the resolver disabled (SHIFT_RESOLVER_ENABLED=false → w.shifts==nil →
// withShift=false), the row must insert with NO shift columns and NO extra
// binds — mirroring the old BuildShiftFill nil-return. This keeps the fold
// a strict superset only when shift resolution is on.
func TestShiftFoldDisabledOmitsColumns(t *testing.T) {
	ts := time.UnixMilli(1_700_000_000_000).Truncate(time.Second).UTC()
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 2, IDArea: 3, IDEquipment: 42}

	q := buildConsumed(ts, info, 1, 5, nil, nil, nil, ts.UnixMilli(), "public", false, nil, nil)
	for _, frag := range []string{"id_shift", "id_shift_hour", "ts_value_production", "::date"} {
		if strings.Contains(q.SQL, frag) {
			t.Errorf("resolver disabled: SQL should not mention %q\nSQL:\n%s", frag, q.SQL)
		}
	}
	if len(q.Args) != 12 {
		t.Errorf("resolver disabled: expected 12 base args, got %d", len(q.Args))
	}
}
