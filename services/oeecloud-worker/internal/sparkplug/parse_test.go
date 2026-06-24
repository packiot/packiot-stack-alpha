package sparkplug

import "testing"

// Sample topics taken from live CPACK staging traffic on 2026-06-22/23.
// New test cases should reflect real production-shape topics — making one
// up risks codifying a misreading of the Sparkplug grammar.

func TestMetricClassify(t *testing.T) {
	intp := func(n int) *int { return &n }
	cases := []struct {
		name string
		topic string
		id   *int
		want MetricKind
	}{
		// Line-level status metrics (type at N-1)
		{"line state", "CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent", nil, KindStateCurrent},
		{"line mode", "CPACK/SC/SLEEVE/SLEEVE1/Status/UnitModeCurrent", nil, KindUnitModeCurrent},
		{"line speed", "CPACK/SC/SLEEVE/SLEEVE1/Status/CurMachSpeed", nil, KindCurMachSpeed},

		// Unit-level counter metrics with doubled-name + counter pattern
		// (type at N-3: .../Admin/{Type}/{id}/Unit)
		{"unit doubled net", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdProcessedCount/107/Unit", nil, KindProdProcessedCount},
		{"unit doubled gross", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdConsumedCount/107/Unit", nil, KindProdConsumedCount},
		{"unit doubled scrap", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdDefectiveCount/107/Unit", nil, KindProdDefectiveCount},

		// Line-level counter metrics (LINHAS pattern, no doubled name)
		{"line counter LINHAS", "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/61/Unit", nil, KindProdConsumedCount},

		// CELULA pattern (doubled name like SLEEVE)
		{"celula counter", "CPACK/SC/CELULA1/HOTMADAG/HOTMADAG/Admin/ProdConsumedCount/87/Unit", nil, KindProdConsumedCount},

		// Parameter requires both name "Parameter" AND id in 30700-30899
		{"parameter 30700 with id", "CPACK/SC/SLEEVE/SLEEVE1/Status/Parameter", intp(30700), KindParameter},
		{"parameter 30899 with id", "CPACK/SC/SLEEVE/SLEEVE1/Status/Parameter", intp(30899), KindParameter},
		{"parameter id out of range", "CPACK/SC/SLEEVE/SLEEVE1/Status/Parameter", intp(99), KindUnknown},
		{"parameter no id", "CPACK/SC/SLEEVE/SLEEVE1/Status/Parameter", nil, KindUnknown},

		// Unknown — empty / garbage / random suffix
		{"empty topic", "", nil, KindUnknown},
		{"random tail", "CPACK/SC/SLEEVE/SLEEVE1/Status/SomethingElse", nil, KindUnknown},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := Metric{Name: c.topic, ID: c.id}
			got := m.Classify()
			if got != c.want {
				t.Errorf("Classify(%q, id=%v) = %s, want %s", c.topic, c.id, got, c.want)
			}
		})
	}
}

func TestMetricTopicForRegister(t *testing.T) {
	cases := []struct {
		name  string
		topic string
		want  string
	}{
		// Line-level metrics drop everything from segment 4 (Admin/Status/Command) on
		{"strip Status", "CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent", "CPACK/SC/SLEEVE/SLEEVE1"},
		{"strip Admin LINHAS", "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/61/Unit", "CPACK/SC/LINHAS/L5"},
		{"strip Command", "CPACK/SC/SLEEVE/SLEEVE1/Command/Foo", "CPACK/SC/SLEEVE/SLEEVE1"},
		{"strip status case-insensitive", "CPACK/SC/SLEEVE/SLEEVE1/status/StateCurrent", "CPACK/SC/SLEEVE/SLEEVE1"},

		// Unit-level metrics keep first 5 segments
		{"unit doubled topic", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdProcessedCount/107/Unit", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1"},
		{"unit CELULA topic", "CPACK/SC/CELULA1/HOTMADAG/HOTMADAG/Admin/ProdConsumedCount/87/Unit", "CPACK/SC/CELULA1/HOTMADAG/HOTMADAG"},

		// Already-short topics pass through unchanged
		{"4 segments unchanged", "CPACK/SC/SLEEVE/SLEEVE1", "CPACK/SC/SLEEVE/SLEEVE1"},
		{"3 segments unchanged", "CPACK/SC/SLEEVE", "CPACK/SC/SLEEVE"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := Metric{Name: c.topic}
			got := m.TopicForRegister()
			if got != c.want {
				t.Errorf("TopicForRegister(%q) = %q, want %q", c.topic, got, c.want)
			}
		})
	}
}

func TestMetricIsLineTopic(t *testing.T) {
	cases := []struct {
		name  string
		topic string
		want  bool
	}{
		{"line Status", "CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent", true},
		{"line Admin", "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/61/Unit", true},
		{"line Command", "CPACK/SC/SLEEVE/SLEEVE1/Command/Foo", true},
		{"line case-insensitive", "CPACK/SC/SLEEVE/SLEEVE1/status/X", true},
		{"unit doubled", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdProcessedCount/107/Unit", false},
		{"unit CELULA", "CPACK/SC/CELULA1/HOTMADAG/HOTMADAG/Admin/ProdConsumedCount/87/Unit", false},
		// Short topics default to line — caller can override
		{"short defaults to line", "CPACK/SC/SLEEVE", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := Metric{Name: c.topic}
			if got := m.IsLineTopic(); got != c.want {
				t.Errorf("IsLineTopic(%q) = %v, want %v", c.topic, got, c.want)
			}
		})
	}
}

func TestParseHappy(t *testing.T) {
	body := []byte(`{
		"timestamp": 1782161858551,
		"gateway":   "simulator",
		"metrics": [
			{"name": "CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent", "timestamp": 1782161858551, "value": 6},
			{"name": "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdProcessedCount/107/Unit",
			 "timestamp": 1782161858600, "value": 12, "counter": 99012, "curspeed": 120}
		]
	}`)
	p, err := Parse(body)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if p.Timestamp != 1782161858551 {
		t.Errorf("payload Timestamp = %d", p.Timestamp)
	}
	if p.Gateway != "simulator" {
		t.Errorf("payload Gateway = %q", p.Gateway)
	}
	if len(p.Metrics) != 2 {
		t.Fatalf("got %d metrics, want 2", len(p.Metrics))
	}
	if p.Metrics[1].Counter == nil || *p.Metrics[1].Counter != 99012 {
		t.Errorf("metric[1].Counter = %v, want 99012", p.Metrics[1].Counter)
	}
	if p.Metrics[1].CurSpeed == nil || *p.Metrics[1].CurSpeed != 120 {
		t.Errorf("metric[1].CurSpeed = %v, want 120", p.Metrics[1].CurSpeed)
	}
}

func TestParseBadJSON(t *testing.T) {
	if _, err := Parse([]byte(`{not json}`)); err == nil {
		t.Error("Parse on bad json: want error, got nil")
	}
}
