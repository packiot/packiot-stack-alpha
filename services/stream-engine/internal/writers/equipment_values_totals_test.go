package writers

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// t-counter-totals-float8 (F1b): the medallion routes dual-write the exact float8 *_total next
// to the float4 *_val, bound to the SAME counter; the legacy public route keeps its old shape
// (its table has no *_total columns, so naming them would fail every insert).
func TestCounterTotalsDualWrite(t *testing.T) {
	ts := time.UnixMilli(1_700_000_000_000).Truncate(time.Second).UTC()
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 2, IDArea: 3, IDEquipment: 42}
	counter := 297_922_487.0
	idShift, idShiftHour := 7, 9

	type build func(schema string, withShift bool) *Query
	cases := []struct {
		name, col string
		base      int // the builder's own binds before any fold
		build     build
	}{
		{"processed", "net_production_total", 12, func(s string, w bool) *Query {
			return buildProcessed(ts, info, 1, 5, &counter, nil, nil, ts.UnixMilli(), s, w, &idShift, &idShiftHour)
		}},
		{"consumed", "gross_production_total", 12, func(s string, w bool) *Query {
			return buildConsumed(ts, info, 1, 5, &counter, nil, nil, ts.UnixMilli(), s, w, &idShift, &idShiftHour)
		}},
		{"defective", "scrap_total", 11, func(s string, w bool) *Query {
			return buildDefective(ts, info, 1, 5, &counter, nil, ts.UnixMilli(), s, w, &idShift, &idShiftHour)
		}},
	}
	for _, c := range cases {
		for _, withShift := range []bool{false, true} {
			name := fmt.Sprintf("%s/shift=%v", c.name, withShift)

			pub := c.build("public", withShift)
			if strings.Contains(pub.SQL, "_total") {
				t.Errorf("%s: public route must not name *_total\nSQL:\n%s", name, pub.SQL)
			}

			q := c.build("silver", withShift)
			wantArgs := c.base + 1
			if withShift {
				wantArgs += 2
			}
			if len(q.Args) != wantArgs {
				t.Fatalf("%s: %d args, want %d", name, len(q.Args), wantArgs)
			}
			// the total bind sits right after the builder's own binds and carries the counter
			if got, ok := q.Args[c.base].(*float64); !ok || got == nil || *got != counter {
				t.Errorf("%s: arg $%d = %v, want the counter %v", name, c.base+1, q.Args[c.base], counter)
			}
			for _, frag := range []string{
				"check_number, " + c.col,
				fmt.Sprintf("$%d, $%d", c.base, c.base+1),
				fmt.Sprintf("%[1]s = COALESCE(EXCLUDED.%[1]s, equipment_values.%[1]s)", c.col),
			} {
				if !strings.Contains(q.SQL, frag) {
					t.Errorf("%s: SQL missing %q\nSQL:\n%s", name, frag, q.SQL)
				}
			}
			// shift binds shift by one and still land last, in order
			if withShift {
				if !strings.Contains(q.SQL, fmt.Sprintf("$%d, $%d, ($1)::date", c.base+2, c.base+3)) {
					t.Errorf("%s: shift binds not renumbered after the total\nSQL:\n%s", name, q.SQL)
				}
				if s, ok := q.Args[len(q.Args)-2].(*int); !ok || *s != idShift {
					t.Errorf("%s: shift bind out of place: %v", name, q.Args)
				}
			}
		}
	}
}

func TestCounterTotalsBronzeAppend(t *testing.T) {
	ts := time.UnixMilli(1_700_000_000_250).UTC()
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 2, IDArea: 3, IDEquipment: 42}
	counter := 297_922_487.0
	for kind, col := range map[sparkplug.MetricKind]string{
		sparkplug.KindProdProcessedCount: "net_production_total",
		sparkplug.KindProdConsumedCount:  "gross_production_total",
		sparkplug.KindProdDefectiveCount: "scrap_total",
	} {
		q := buildRawAppend(kind, ts, info, 1, 5, &counter, nil, nil, nil, 1, "bronze")
		if !strings.HasSuffix(strings.SplitN(q.SQL, ")", 2)[0], ", "+col) {
			t.Errorf("%s: %s must be the last column\nSQL: %s", kind, col, q.SQL)
		}
		if got, ok := q.Args[len(q.Args)-1].(*float64); !ok || *got != counter {
			t.Errorf("%s: last arg %v, want the counter", kind, q.Args[len(q.Args)-1])
		}
		if strings.Count(q.SQL, "$") != len(q.Args) {
			t.Errorf("%s: %d placeholders for %d args", kind, strings.Count(q.SQL, "$"), len(q.Args))
		}
		if pub := buildRawAppend(kind, ts, info, 1, 5, &counter, nil, nil, nil, 1, "public"); strings.Contains(pub.SQL, "_total") {
			t.Errorf("%s: public raw append must not name *_total", kind)
		}
	}
	// non-counter kinds never carry a total
	if q := buildRawAppend(sparkplug.KindStateCurrent, ts, info, 1, 6, &counter, nil, nil, nil, 1, "bronze"); strings.Contains(q.SQL, "_total") {
		t.Errorf("state raw append must not name *_total")
	}
}

func TestSeedExprPrefersExactTotal(t *testing.T) {
	for _, c := range []struct{ schema, col, want string }{
		{"silver", "net_production_val", "COALESCE(net_production_total, net_production_val)"},
		{"silver", "gross_production_val", "COALESCE(gross_production_total, gross_production_val)"},
		{"silver", "scrap_val", "COALESCE(scrap_total, scrap_val)"},
		{"public", "net_production_val", "net_production_val"},
	} {
		if got := seedExpr(c.schema, c.col); got != c.want {
			t.Errorf("seedExpr(%q, %q) = %q, want %q", c.schema, c.col, got, c.want)
		}
	}
}

// COUNTER_TOTALS_PUBLIC: the public route names *_total only when enabled (prod forward-port).
func TestCounterTotalsPublicFlag(t *testing.T) {
	ts := time.UnixMilli(1_700_000_000_000).Truncate(time.Second).UTC()
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 2, IDArea: 3, IDEquipment: 42}
	counter := 297_922_487.0
	t.Cleanup(func() { SetPublicCounterTotals(false) })

	if q := buildConsumed(ts, info, 1, 5, &counter, nil, nil, ts.UnixMilli(), "public", false, nil, nil); strings.Contains(q.SQL, "_total") {
		t.Fatalf("flag off: public must not name *_total")
	}
	if got := seedExpr("public", "gross_production_val"); got != "gross_production_val" {
		t.Fatalf("flag off: seed reads *_val only, got %q", got)
	}
	SetPublicCounterTotals(true)
	q := buildConsumed(ts, info, 1, 5, &counter, nil, nil, ts.UnixMilli(), "public", false, nil, nil)
	if !strings.Contains(q.SQL, "check_number, gross_production_total") || len(q.Args) != 13 {
		t.Fatalf("flag on: public must dual-write gross_production_total (args=%d)\nSQL:\n%s", len(q.Args), q.SQL)
	}
	if raw := buildRawAppend(sparkplug.KindProdProcessedCount, ts, info, 1, 5, &counter, nil, nil, nil, 1, "public"); !strings.Contains(raw.SQL, "net_production_total") {
		t.Fatalf("flag on: public raw append must carry net_production_total")
	}
	if got := seedExpr("public", "gross_production_val"); got != "COALESCE(gross_production_total, gross_production_val)" {
		t.Fatalf("flag on: seed prefers the exact total, got %q", got)
	}
}
