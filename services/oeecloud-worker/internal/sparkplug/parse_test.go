package sparkplug

import (
	"encoding/json"
	"testing"
)

// TestParseTolerantNumbers — Incoplast's PackML2SparkPlug node string-encodes
// numeric fields (id, counter, curspeed). The whole payload must still parse;
// a naive *int/*float64 field would fail the unmarshal and drop every metric.
func TestParseTolerantNumbers(t *testing.T) {
	// id as a quoted string, counter/curspeed as quoted strings.
	body := []byte(`{"timestamp":1782161858551,"gateway":"incoplast-nr","metrics":[` +
		`{"name":"INCOPLAST/SL/IMP/M1/M1/Status/Parameter","id":"30700","counter":"120","curspeed":"88.5"}]}`)
	p, err := Parse(body)
	if err != nil {
		t.Fatalf("Parse must tolerate string-encoded numbers, got: %v", err)
	}
	if len(p.Metrics) != 1 {
		t.Fatalf("want 1 metric, got %d", len(p.Metrics))
	}
	m := p.Metrics[0]
	if m.ID == nil || int(*m.ID) != 30700 {
		t.Fatalf("id: want 30700, got %v", m.ID)
	}
	if m.Counter == nil || float64(*m.Counter) != 120 {
		t.Fatalf("counter: want 120, got %v", m.Counter)
	}
	// A plain JSON number must still work (CPACK path).
	p2, err := Parse([]byte(`{"metrics":[{"name":"x","id":30800}]}`))
	if err != nil || p2.Metrics[0].ID == nil || int(*p2.Metrics[0].ID) != 30800 {
		t.Fatalf("numeric id must still parse, got err=%v", err)
	}
}

// Sample topics taken from live CPACK staging traffic on 2026-06-22/23.
// New test cases should reflect real production-shape topics — making one
// up risks codifying a misreading of the Sparkplug grammar.

func TestMetricClassify(t *testing.T) {
	intp := func(n int) *jsonInt { v := jsonInt(n); return &v }
	cases := []struct {
		name  string
		topic string
		id    *jsonInt
		want  MetricKind
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

func TestParse_StringEncodedNumerics(t *testing.T) {
	// Incoplast's PackML2SparkPlug encodes curspeed/counter as JSON strings.
	body := []byte(`{"metrics":[{"name":"x","timestamp":1782161858600,"value":12,"counter":"99012","curspeed":"120.5"}]}`)
	p, err := Parse(body)
	if err != nil {
		t.Fatalf("string-encoded numerics must parse: %v", err)
	}
	m := p.Metrics[0]
	if m.Counter == nil || float64(*m.Counter) != 99012 {
		t.Errorf("counter: got %v want 99012", m.Counter)
	}
	if m.CurSpeed == nil || float64(*m.CurSpeed) != 120.5 {
		t.Errorf("curspeed: got %v want 120.5", m.CurSpeed)
	}
	// numbers (CPACK) must still work
	body2 := []byte(`{"metrics":[{"name":"x","timestamp":1,"value":1,"counter":42,"curspeed":88}]}`)
	p2, err := Parse(body2)
	if err != nil || float64(*p2.Metrics[0].CurSpeed) != 88 {
		t.Errorf("numeric curspeed regressed: %v err=%v", p2.Metrics[0].CurSpeed, err)
	}
}

// TestParse_EncodingContract pins the producer→consumer wire contract on the
// `oee` exchange: a producer must marshal the envelope EXACTLY ONCE, so the
// AMQP body is a JSON object (`{...}`), which Parse round-trips. If a producer
// double-encodes — marshals the already-serialized JSON a second time — the
// body becomes a JSON *string* (`"{...}"`) and Parse MUST reject it. That
// rejection is the mechanism that dead-letters the message to oee-failed
// (nack → oee-retry → after MaxRetries → oee-failed) instead of silently
// mis-ingesting it.
//
// Regression this guards (task #14): the edge-node-red "Relay to RabbitMQ"
// (plcdata-fn) function published to the RabbitMQ management API with
// `payload_encoding:"string"` + `payload: JSON.stringify(rmqPayload)`. When
// rmqPayload arrived as an already-serialized string (e.g. the boot/reconcile
// race that loaded the orphaned HTTP-Ingestion tab), that stringify ran a
// SECOND time and the delivered body was `"{\"timestamp\":...}"` — a JSON
// string of JSON. Every such message rejected here → oee-failed. The producer
// was removed from flows.json; this test locks the contract so no future
// producer (or a "tolerant" change to Parse) can reintroduce a silently-
// accepted double-encode.
func TestParse_EncodingContract(t *testing.T) {
	env := Payload{
		Timestamp: 1782161858551,
		Gateway:   "simulator",
		Metrics: []Metric{
			{Name: "CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent", Timestamp: 1782161858551, Value: json.RawMessage(`6`)},
		},
	}

	// Single-encode: the correct wire shape. Round-trips through Parse.
	single, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if single[0] != '{' {
		t.Fatalf("single-encoded body must start with '{', got %q", single[0])
	}
	got, err := Parse(single)
	if err != nil {
		t.Fatalf("single-encoded body must Parse: %v", err)
	}
	if got.Timestamp != env.Timestamp || got.Gateway != env.Gateway || len(got.Metrics) != 1 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	if got.Metrics[0].Name != env.Metrics[0].Name {
		t.Fatalf("metric name round-trip: got %q", got.Metrics[0].Name)
	}

	// Double-encode: marshal the already-serialized JSON a second time. This is
	// exactly what plcdata-fn produced — the body becomes a quoted JSON string.
	double, err := json.Marshal(string(single))
	if err != nil {
		t.Fatalf("double-marshal: %v", err)
	}
	if double[0] != '"' {
		t.Fatalf("double-encoded body must be a JSON string starting with '\"', got %q", double[0])
	}
	if _, err := Parse(double); err == nil {
		t.Fatal("double-encoded body must be REJECTED by Parse (→ dead-letter), got nil error — " +
			"a tolerant decode here would silently mis-ingest double-encoded messages")
	}

	// IsJSONStringBody must FLAG the double-encoded body (top-level JSON string)
	// and NOT the correct single-encoded object. This is the predicate the
	// worker uses to drop-not-retry the poison (task #92); if it misclassified
	// the object it would silently drop good traffic.
	if !IsJSONStringBody(double) {
		t.Fatal("IsJSONStringBody must return true for a double-encoded (JSON-string) body")
	}
	if IsJSONStringBody(single) {
		t.Fatal("IsJSONStringBody must return false for a correct single-encoded object body")
	}
}

// TestIsJSONStringBody covers the top-level-token discrimination the #92
// poison-storm guard depends on: only a bare JSON string (`"..."`, the
// double-encode signature that yields `cannot unmarshal string into
// ...Payload`) is dropped; every object body — including one with leading
// insignificant whitespace — must pass through to the normal parse path.
func TestIsJSONStringBody(t *testing.T) {
	tests := []struct {
		name string
		body string
		want bool
	}{
		{"object", `{"timestamp":1,"metrics":[]}`, false},
		{"object leading whitespace", "  \n\t{\"timestamp\":1}", false},
		{"double-encoded string of object", `"{\"timestamp\":1}"`, true},
		{"double-encoded string leading ws", "\n \"{\\\"a\\\":1}\"", true},
		{"bare string", `"hello"`, true},
		{"array", `[1,2,3]`, false},
		{"number", `42`, false},
		{"empty", ``, false},
		{"whitespace only", "   \n", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsJSONStringBody([]byte(tt.body)); got != tt.want {
				t.Errorf("IsJSONStringBody(%q) = %v, want %v", tt.body, got, tt.want)
			}
		})
	}
}
