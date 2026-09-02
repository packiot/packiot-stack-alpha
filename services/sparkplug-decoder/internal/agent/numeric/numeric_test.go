package numeric

import (
	"reflect"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
)

// bispharma-shaped raw_tag_map fragment (two members off L01, from the real
// descriptor: count_index.value 164 and 167).
func bispharmaTagMap() []agentcfg.TagMapEntry {
	return []agentcfg.TagMapEntry{
		{MetricSuffix: "/LINHAS/L01/S3/Admin/ProdProcessedCount/164/Unit", Type: "double"},
		{MetricSuffix: "/LINHAS/L01/S6_OUTPUT/Admin/ProdProcessedCount/167/Unit", Type: "double"},
		// non-count leaves that MUST be skipped:
		{MetricSuffix: "/LINHAS/L01/Admin/ProdProcessedCount", Type: "double"}, // bare line count, no idx
		{MetricSuffix: "/LINHAS/L01/Status/MachSpeed", Type: "double"},         // not a count
		{MetricSuffix: "/LINHAS/L01/Status/Parameter30700", Type: "string"},    // not a count
	}
}

func TestBuildIndexFromTagMap_ExtractsCountLeaves(t *testing.T) {
	got, err := BuildIndexFromTagMap(bispharmaTagMap())
	if err != nil {
		t.Fatalf("BuildIndexFromTagMap: %v", err)
	}
	want := map[int]Target{
		164: {Suffix: "/LINHAS/L01/S3/Admin/ProdProcessedCount/164/Unit", Type: "double"},
		167: {Suffix: "/LINHAS/L01/S6_OUTPUT/Admin/ProdProcessedCount/167/Unit", Type: "double"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("table mismatch:\n got %+v\nwant %+v", got, want)
	}
}

func TestBuildIndexFromTagMap_ConsumedAndDefectiveCounts(t *testing.T) {
	// The full counters-only template family — Processed / Consumed / Defective —
	// all end in <...Count>/<idx>/Unit and must all be extracted.
	entries := []agentcfg.TagMapEntry{
		{MetricSuffix: "/L1/M/Admin/ProdProcessedCount/10/Unit", Type: "double"},
		{MetricSuffix: "/L1/M/Admin/ProdConsumedCount/11/Unit", Type: "double"},
		{MetricSuffix: "/L1/M/Admin/ProdDefectiveCount/12/Unit", Type: "double"},
	}
	got, err := BuildIndexFromTagMap(entries)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != 3 || got[11].Suffix != "/L1/M/Admin/ProdConsumedCount/11/Unit" {
		t.Fatalf("expected 3 count leaves incl. Consumed; got %+v", got)
	}
}

func TestBuildIndexFromTagMap_DuplicateIndexIsError(t *testing.T) {
	entries := []agentcfg.TagMapEntry{
		{MetricSuffix: "/L1/A/Admin/ProdProcessedCount/99/Unit", Type: "double"},
		{MetricSuffix: "/L2/B/Admin/ProdProcessedCount/99/Unit", Type: "double"},
	}
	if _, err := BuildIndexFromTagMap(entries); err == nil {
		t.Fatal("expected an error on duplicate count index 99, got nil")
	}
}

func TestCountIndexOf(t *testing.T) {
	cases := []struct {
		suffix  string
		wantIdx int
		wantOK  bool
	}{
		{"/LINHAS/L01/S3/Admin/ProdProcessedCount/164/Unit", 164, true},
		{"/L/M/Admin/ProdConsumedCount/0/Unit", 0, true},
		{"/L/Admin/ProdProcessedCount", 0, false},              // no idx segment
		{"/L/M/Status/MachSpeed", 0, false},                    // not a count
		{"/L/M/Admin/ProdProcessedCount/164/Widget", 0, false}, // not /Unit
		{"/L/M/Admin/ProdProcessedCount/x/Unit", 0, false},     // non-numeric idx
		{"/L/M/Admin/SomethingElse/5/Unit", 0, false},          // penultimate parent not *Count
	}
	for _, c := range cases {
		idx, ok := countIndexOf(c.suffix)
		if ok != c.wantOK || (ok && idx != c.wantIdx) {
			t.Errorf("countIndexOf(%q) = (%d,%v); want (%d,%v)", c.suffix, idx, ok, c.wantIdx, c.wantOK)
		}
	}
}

func TestTranslate_MapsAbsoluteValueAndFlagsUnmapped(t *testing.T) {
	table, _ := BuildIndexFromTagMap(bispharmaTagMap())
	tr := NewTranslator(table)

	counters := []Counter{
		{ID: 164, Value: 12345},
		{ID: 167, Value: 67890},
		{ID: 999, Value: 1}, // unmapped legacy id
		{ID: 999, Value: 2}, // duplicate unmapped — must dedup in the report
	}
	tags, unmapped := tr.Translate(counters, "bispharma-edge", 1700000000000)

	if len(tags) != 2 {
		t.Fatalf("expected 2 translated tags, got %d", len(tags))
	}
	byMetric := map[string]float64{}
	for _, tg := range tags {
		byMetric[tg.Metric] = tg.Value.(float64)
		if tg.EndpointOrPath != "bispharma-edge" {
			t.Errorf("endpoint not stamped: %q", tg.EndpointOrPath)
		}
		if tg.TsMillis != 1700000000000 {
			t.Errorf("ts fallback not applied: %d", tg.TsMillis)
		}
		if !tg.Quality {
			t.Errorf("quality should default good")
		}
	}
	// ABSOLUTE value forwarded verbatim (the stack derives the delta, not us).
	if byMetric["/LINHAS/L01/S3/Admin/ProdProcessedCount/164/Unit"] != 12345 {
		t.Errorf("id 164 abs value: %v", byMetric)
	}
	if len(unmapped) != 1 || unmapped[0] != 999 {
		t.Errorf("unmapped report: got %v, want [999]", unmapped)
	}
}

func TestDecodeEnvelope_FlatAndNested(t *testing.T) {
	// Flat form (bispharma-shaped).
	flat := `{"group":"BISPHARMA","gateway":"bispharma-edge","timestamp":1700000000000,
	  "counterData":[{"id":164,"value":100},{"id":167,"value":200}]}`
	env, counters, err := DecodeEnvelope([]byte(flat))
	if err != nil {
		t.Fatalf("flat decode: %v", err)
	}
	if env.Group != "BISPHARMA" || env.EnvelopeTS() != 1700000000000 || len(counters) != 2 {
		t.Fatalf("flat: group=%q ts=%d n=%d", env.Group, env.EnvelopeTS(), len(counters))
	}

	// Nested per-endpoint form (bisnago-shaped).
	nested := `{"group":"BISNAGO","scan_ts":1700000001000,
	  "counters":[
	    {"endpoint":"L71","counterData":[{"id":670,"value":1},{"id":671,"value":2}]},
	    {"endpoint":"L72","counterData":[{"id":672,"value":3}]}
	  ]}`
	env2, counters2, err := DecodeEnvelope([]byte(nested))
	if err != nil {
		t.Fatalf("nested decode: %v", err)
	}
	if env2.EnvelopeTS() != 1700000001000 || len(counters2) != 3 {
		t.Fatalf("nested: ts=%d n=%d", env2.EnvelopeTS(), len(counters2))
	}
}

func TestTranslate_PerCounterQualityAndTS(t *testing.T) {
	tr := NewTranslator(map[int]Target{5: {Suffix: "/L/M/Admin/ProdProcessedCount/5/Unit", Type: "double"}})
	bad := false
	tags, _ := tr.Translate([]Counter{{ID: 5, Value: 9, Q: &bad, TS: 42}}, "e", 1)
	if len(tags) != 1 || tags[0].Quality || tags[0].TsMillis != 42 {
		t.Fatalf("per-counter q/ts not honored: %+v", tags)
	}
}
