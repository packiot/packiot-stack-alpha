package main

import (
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

func d(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

func TestPlanEVDaily_SplitsExactlyAtWatermark(t *testing.T) {
	wm := d("2026-09-26T00:00:00Z")
	p := planEVDaily(d("2025-09-01T00:00:00Z"), d("2026-09-28T00:00:00Z"), &wm)
	if !p.ColdFrom.Equal(d("2025-09-01T00:00:00Z")) || !p.ColdTo.Equal(wm) {
		t.Fatalf("cold = [%v,%v), want [2025-09-01, watermark)", p.ColdFrom, p.ColdTo)
	}
	if !p.HotFrom.Equal(wm) || !p.HotTo.Equal(d("2026-09-28T00:00:00Z")) {
		t.Fatalf("hot = [%v,%v), want [watermark, 2026-09-28)", p.HotFrom, p.HotTo)
	}
	// The two slices must tile the window: no day counted twice, none dropped.
	if !p.ColdTo.Equal(p.HotFrom) {
		t.Fatalf("gap/overlap at the watermark: cold ends %v, hot starts %v", p.ColdTo, p.HotFrom)
	}
}

func TestPlanEVDaily_WholeDayResolution(t *testing.T) {
	wm := d("2026-01-01T00:00:00Z")
	p := planEVDaily(d("2025-03-10T15:30:00Z"), d("2025-06-02T08:00:00Z"), &wm)
	if !p.ColdFrom.Equal(d("2025-03-10T00:00:00Z")) || !p.ColdTo.Equal(d("2025-06-03T00:00:00Z")) {
		t.Fatalf("cold = [%v,%v), want floor(from) .. ceil(to)", p.ColdFrom, p.ColdTo)
	}
	if !p.HotFrom.IsZero() {
		t.Fatalf("window entirely before the watermark must not query hot, got [%v,%v)", p.HotFrom, p.HotTo)
	}
}

func TestPlanEVDaily_NoWatermarkIsAllHot(t *testing.T) {
	// Non-promoted tenant: the union view serves no cold rows, so neither do we.
	p := planEVDaily(d("2025-01-01T00:00:00Z"), d("2026-01-01T00:00:00Z"), nil)
	if !p.ColdFrom.IsZero() {
		t.Fatalf("no watermark must mean no cold query, got [%v,%v)", p.ColdFrom, p.ColdTo)
	}
	if !p.HotFrom.Equal(d("2025-01-01T00:00:00Z")) || !p.HotTo.Equal(d("2026-01-01T00:00:00Z")) {
		t.Fatalf("hot = [%v,%v)", p.HotFrom, p.HotTo)
	}
}

func TestPlanEVDaily_WindowAfterWatermarkIsAllHot(t *testing.T) {
	wm := d("2025-01-01T00:00:00Z")
	p := planEVDaily(d("2025-06-01T00:00:00Z"), d("2025-08-01T00:00:00Z"), &wm)
	if !p.ColdFrom.IsZero() || !p.HotFrom.Equal(d("2025-06-01T00:00:00Z")) {
		t.Fatalf("plan = %+v", p)
	}
}

func TestEEColdWindow_MirrorsUnionPredicate(t *testing.T) {
	from, to := d("2021-11-01T00:00:00Z"), d("2022-02-01T00:00:00Z")
	cut := d("2021-12-15T20:30:00Z")
	if _, _, ok := eeColdWindow(from, to, false, &cut); ok {
		t.Fatal("non-promoted tenant must get no cold events")
	}
	cf, ct, ok := eeColdWindow(from, to, true, &cut)
	if !ok || !cf.Equal(from) || !ct.Equal(cut) {
		t.Fatalf("cold = [%v,%v) ok=%v, want [from, cutover)", cf, ct, ok)
	}
	if _, _, ok := eeColdWindow(d("2022-01-01T00:00:00Z"), to, true, &cut); ok {
		t.Fatal("window after the cutover must not read cold")
	}
	if _, ct, ok := eeColdWindow(from, to, true, nil); !ok || !ct.Equal(to) {
		t.Fatal("promoted without a cutover row serves all cold, like the view")
	}
}

func TestMergeDaily_SumsNullsAndOrder(t *testing.T) {
	day1, day2 := d("2026-09-25T00:00:00Z"), d("2026-09-26T00:00:00Z")
	cold := []map[string]any{
		{"day": day2, "id_equipment": int32(48), "gross_production": 10.0, "net_production": nil},
		{"day": day1, "id_equipment": int32(47), "gross_production": 5.0, "net_production": 4.0},
	}
	hot := []map[string]any{
		{"day": "2026-09-26", "id_equipment": int64(48), "gross_production": 2.0, "net_production": nil},
		{"day": day1, "id_equipment": int32(47), "gross_production": 1.0, "net_production": 1.0},
	}
	out := mergeDaily([][]map[string]any{cold, hot}, []string{"day", "id_equipment"}, []string{"gross_production", "net_production"}, 100)
	if len(out) != 2 {
		t.Fatalf("got %d rows, want 2 (same day+equipment across sides must merge)", len(out))
	}
	if !out[0]["day"].(time.Time).Equal(day1) || out[0]["gross_production"] != 6.0 || out[0]["net_production"] != 5.0 {
		t.Fatalf("row0 = %v", out[0])
	}
	if out[1]["gross_production"] != 12.0 || out[1]["net_production"] != nil {
		t.Fatalf("row1 = %v (an all-null sum must stay null, not 0)", out[1])
	}
	if got := mergeDaily([][]map[string]any{cold, hot}, []string{"day", "id_equipment"}, []string{"gross_production"}, 1); len(got) != 1 {
		t.Fatal("row limit not applied")
	}
}

func TestSplitSQL_TenantFencedAndNeverNow(t *testing.T) {
	for name, sql := range map[string]string{
		"ev watermark": histEVWatermarkSQL, "ev cold": histEVDailyColdSQL, "ev hot": histEVDailyHotSQL,
		"ee boundary": histEEBoundarySQL, "ee hot": histEEHotSQL, "ee cold": histEEColdSQL,
	} {
		if !strings.Contains(sql, "id_enterprise = $1") {
			t.Errorf("%s: missing the server-resolved tenant fence (id_enterprise = $1)", name)
		}
		if strings.Contains(strings.ToLower(sql), "now()") {
			t.Errorf("%s: uses now(), which postgres_fdw never ships (full remote scan)", name)
		}
	}
	for name, sql := range map[string]string{"ev cold": histEVDailyColdSQL, "ee cold": histEEColdSQL} {
		if !strings.Contains(sql, "year >  $4") || !strings.Contains(sql, "year <  $6") {
			t.Errorf("%s: missing the year/month partition prune", name)
		}
	}
}

func TestMergeDaily_NumericFromDuckDB(t *testing.T) {
	// DuckDB returns sum(integer) as HUGEINT -> pgx numeric; it must add up, not vanish to null.
	num := pgtype.Numeric{Int: big.NewInt(3600), Exp: 0, Valid: true}
	out := mergeDaily([][]map[string]any{
		{{"day": d("2021-12-01T00:00:00Z"), "id_equipment": int32(47), "planned_downtime": false, "event_count": int64(2), "downtime_seconds": num}},
		{{"day": d("2021-12-01T00:00:00Z"), "id_equipment": int32(47), "planned_downtime": false, "event_count": int64(1), "downtime_seconds": int64(600)}},
	}, []string{"day", "id_equipment", "planned_downtime"}, []string{"event_count", "downtime_seconds"}, 10)
	if len(out) != 1 || out[0]["downtime_seconds"] != 4200.0 || out[0]["event_count"] != 3.0 {
		t.Fatalf("got %v, want one row with 4200 s / 3 events", out)
	}
}
