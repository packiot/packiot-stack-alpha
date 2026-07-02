package main

import (
	"strings"
	"testing"
	"time"
)

func TestCompileEnforcesCatalogAndTenancy(t *testing.T) {
	base := queryReq{Metrics: []string{"net_production"}, Dimensions: []string{"equipment"},
		Grain: "1hour", From: time.Now().Add(-24 * time.Hour), To: time.Now()}
	sql, args, err := compile(base, 3)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "FROM agg_equipment_values_1hour") ||
		!strings.Contains(sql, "id_enterprise = $1") || args[0] != 3 {
		t.Errorf("tenancy/grain not enforced: %s %v", sql, args)
	}
	if !strings.Contains(sql, "LIMIT 10000") {
		t.Error("row limit missing")
	}
	for _, bad := range []queryReq{
		{Metrics: []string{"pg_sleep"}, Grain: "1hour", From: base.From, To: base.To},
		{Metrics: []string{"net_production"}, Grain: "raw", From: base.From, To: base.To},
		{Metrics: []string{"net_production"}, Dimensions: []string{"x; DROP"}, Grain: "1hour", From: base.From, To: base.To},
		{Metrics: []string{"net_production"}, Grain: "1min", From: time.Now().Add(-30 * 24 * time.Hour), To: time.Now()}, // window > budget
	} {
		if _, _, err := compile(bad, 3); err == nil {
			t.Errorf("compile accepted invalid request: %+v", bad)
		}
	}
}

func TestParseAPIKeys(t *testing.T) {
	m := parseAPIKeys("a:3, b:2,broken,:9")
	if m["a"] != 3 || m["b"] != 2 || len(m) != 2 {
		t.Errorf("parseAPIKeys: %v", m)
	}
}
