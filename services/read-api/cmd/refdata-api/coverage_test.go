package main

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

const day = 24 * time.Hour

func TestResolveCoverage(t *testing.T) {
	rels := []relKeep{
		{"silver.equipment_categorical_1hour", 395 * day},
		{"silver.equipment_metrics_1min", 90 * day},
		{"silver.equipment_events", 5 * 365 * day},
	}
	fnDefs := map[string]string{
		// direct reader of a 13-month cagg + an unbounded gold table
		"oee_score_by_team": "SELECT ... FROM gold.equipment_oee_shift JOIN equipment_categorical_1hour c ...",
		// two-level: wrapper → inner serving fn → 90-day cagg
		"timeline_wrapper": "RETURN QUERY SELECT * FROM serving.timeline_inner(a, b);",
		"timeline_inner":   "SELECT * FROM silver.equipment_metrics_1min m WHERE ...",
		// reads BOTH a 90d and a 13mo relation → most restrictive (90d) wins
		"mixed": "SELECT * FROM equipment_metrics_1min, equipment_categorical_1hour",
		// word boundary: equipment_events_man is NOT equipment_events
		"manual_only": "SELECT * FROM silver.equipment_events_man",
		// unbounded only
		"oee_score": "SELECT * FROM gold.equipment_oee_shift",
	}
	dsSQL := map[string]string{
		"teams":    `SELECT * FROM serving.oee_score_by_team($1,$2)`,
		"timeline": `SELECT * FROM serving.timeline_wrapper($1,$2)`,
		"mixed":    `SELECT * FROM serving.mixed($1)`,
		"manual":   `SELECT * FROM serving.manual_only($1)`,
		"score":    `SELECT * FROM serving.oee_score($1,$2,$3)`,
		"plainsql": `SELECT count(*) FROM silver.equipment_events WHERE id_enterprise=$1`,
	}
	got := resolveCoverage(rels, fnDefs, dsSQL)

	cases := []struct {
		ds      string
		want    time.Duration
		wantRel string
		present bool
	}{
		{"teams", 395 * day, "silver.equipment_categorical_1hour", true},
		{"timeline", 90 * day, "silver.equipment_metrics_1min", true},
		{"mixed", 90 * day, "silver.equipment_metrics_1min", true},
		{"manual", 0, "", false},
		{"score", 0, "", false},
		{"plainsql", 5 * 365 * day, "silver.equipment_events", true},
	}
	for _, c := range cases {
		cov, ok := got[c.ds]
		if ok != c.present {
			t.Errorf("%s: present=%v want %v (%+v)", c.ds, ok, c.present, cov)
			continue
		}
		if ok && (cov.keep != c.want || cov.relation != c.wantRel) {
			t.Errorf("%s: got %v/%s want %v/%s", c.ds, cov.keep, cov.relation, c.want, c.wantRel)
		}
	}
}

func TestSetCoverageHeaders(t *testing.T) {
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	cov := datasetCoverage{keep: 90 * day, relation: "silver.equipment_metrics_1min"}
	floor := now.Add(-90 * day)

	// window inside coverage → floor advertised, NOT truncated
	h := http.Header{}
	setCoverageHeaders(h, cov, floor.Add(time.Hour), now)
	if h.Get("X-Data-Hot-Floor") != floor.Format(time.RFC3339) {
		t.Fatalf("floor header = %q", h.Get("X-Data-Hot-Floor"))
	}
	if h.Get("X-Data-Truncated") != "" || h.Get("Warning") != "" {
		t.Fatalf("in-coverage window must not be flagged: %v", h)
	}
	if !strings.Contains(h.Get("Access-Control-Expose-Headers"), "X-Data-Truncated") {
		t.Fatalf("browser JS must be able to read the headers: %v", h)
	}

	// window before the floor → truncated + Warning naming the relation
	h = http.Header{}
	setCoverageHeaders(h, cov, floor.Add(-day), now)
	if h.Get("X-Data-Truncated") != "true" {
		t.Fatalf("expected truncated, got %v", h)
	}
	if w := h.Get("Warning"); !strings.HasPrefix(w, "299 read-api ") || !strings.Contains(w, "silver.equipment_metrics_1min") {
		t.Fatalf("warning = %q", w)
	}

	// no window (non-windowed dataset) → floor only
	h = http.Header{}
	setCoverageHeaders(h, cov, time.Time{}, now)
	if h.Get("X-Data-Truncated") != "" {
		t.Fatalf("zero window must not be flagged")
	}
}

// Every dataset resolves without panicking against the REAL registry (regex safety
// over all real SQL, including the empty-fnDefs fail-open case).
func TestResolveCoverageRealRegistry(t *testing.T) {
	dsSQL := map[string]string{}
	for name, ds := range datasets {
		dsSQL[name] = ds.sql + "\n" + ds.sqlAnalytics
	}
	rels := []relKeep{{"silver.equipment_metrics_1min", 90 * day}}
	got := resolveCoverage(rels, map[string]string{}, dsSQL)
	for name := range got {
		if _, ok := datasets[name]; !ok {
			t.Fatalf("unknown dataset %q in result", name)
		}
	}
}
