package clientdescriptor

// reader_contract_test.go is the golden guard for the Tier-1 ↔ Tier-2 WIRE CONTRACT
// that silently broke three times during the CPACK go-live. The generated Node-RED
// reader flow (GeneratePlcReaderFlow) POSTs a JSON envelope to the agent's /v1/tags;
// the agent decodes it with rawtag.Decode and resolves each tag's metric against the
// raw_tag_map keyed by metric SUFFIX (agentcfg.Config.TagMap). Each of these was a
// live, silent, all-data-dropped failure that a reader-only OR agent-only test would
// have missed — the break is in the SEAM between the two halves:
//
//   F4  the reader must send the auth header X-Ingest-Key (from env AGENT_INGEST_API_KEY),
//       else the ingest front door 401s every POST.
//   F5  the envelope must be { endpoint, scan_ts, tags:[{metric,value,ts}] } — NOT the
//       old { timestamp, gateway, metrics:[{name,…}] } shape: the latter decodes to
//       ZERO tags (no "tags" key), so every reading is silently discarded.
//   F6  metric must be the canonical SUFFIX (full topic minus the tenant prefix
//       d.Canonical.Prefix), because the tag map is keyed by suffix. A full-canonical
//       metric decodes fine but resolves to NOTHING — every tag dropped as unmapped
//       (the live "accepted: 0" bug).
//
// The load-bearing assertion is accepted == total: every tag the reader emits for a
// sample PLC reading both DECODES (F5) and RESOLVES against the agent's suffix-keyed
// map (F6). Two negative sub-cases prove the test has teeth: the old envelope shape
// decodes to total == 0, and a full-canonical metric resolves to accepted == 0.
//
// It reuses the package's readerDescriptorYAML fixture (a real, validated three-protocol
// descriptor) and the containsAll helper — both defined in generate_reader_test.go.

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
)

// sampleReading is one physical PLC tag the reader would read: the equipment's
// packml_topic + the tag's metric leaf gives the FULL canonical topic that the
// source node (s7 vartable name / opcua item name / modbus-read topic) carries.
type sampleReading struct {
	packmlTopic string // equipment canonical prefix, e.g. "CPACK/SC/LINHAS/L8/DXL"
	metric      string // tag leaf, e.g. "/Status/MachSpeed"
	value       float64
}

// wireTag mirrors the { metric, value, ts } object the reader's normalize function
// pushes into the envelope's tags[] — see readerFunctionBody in generate_reader.go.
type wireTag struct {
	Metric string  `json:"metric"`
	Value  float64 `json:"value"`
	TS     int64   `json:"ts"`
}

// wireEnvelope mirrors the { endpoint, scan_ts, tags[] } payload the reader POSTs to
// /v1/tags — the SAME shape rawtag.Decode consumes (F5). Built here from scratch so
// the test asserts the contract, not the generator's own marshalling.
type wireEnvelope struct {
	Endpoint string    `json:"endpoint"`
	ScanTS   int64     `json:"scan_ts"`
	Tags     []wireTag `json:"tags"`
}

// TestReaderContractStatic is the cheap first line of defence: it asserts the
// GENERATED normalize function string carries the F4/F5/F6 wiring, so a generator
// regression (someone re-introducing the old header/envelope/keying) fails at build
// time without needing to stand anything up.
func TestReaderContractStatic(t *testing.T) {
	d, err := Parse([]byte(readerDescriptorYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	out, err := d.GeneratePlcReaderFlow()
	if err != nil {
		t.Fatalf("GeneratePlcReaderFlow: %v", err)
	}

	var nodes []map[string]any
	if err := json.Unmarshal(out, &nodes); err != nil {
		t.Fatalf("generated flow is not a JSON array: %v", err)
	}
	var body string
	for _, n := range nodes {
		if n["type"] == "function" {
			body, _ = n["func"].(string)
			break
		}
	}
	if body == "" {
		t.Fatal("generated flow has no normalize function node")
	}

	// F4 — the auth header is set from the ingest-key env var.
	if !containsAll(body, "X-Ingest-Key", `env.get("AGENT_INGEST_API_KEY")`) {
		t.Errorf("F4: normalize fn missing X-Ingest-Key / AGENT_INGEST_API_KEY wiring:\n%s", body)
	}

	// F5 — the NEW envelope shape (scan_ts + tags[] + metric), and NOT the old one.
	if !containsAll(body, "scan_ts", "tags:", "metric:") {
		t.Errorf("F5: normalize fn does not emit the { scan_ts, tags:[{metric,…}] } envelope:\n%s", body)
	}
	for _, bad := range []string{"gateway:", "metrics:"} {
		if strings.Contains(body, bad) {
			t.Errorf("F5: normalize fn still emits the OLD envelope token %q — the agent drops it:\n%s", bad, body)
		}
	}

	// F6 — the metric is the SUFFIX: the fn strips the descriptor's canonical prefix.
	// The strip may be expressed as .slice(PREFIX.length) or a prefix .replace; either
	// way the load-bearing thing is that the tenant prefix is referenced and removed.
	if !containsAll(body, `PREFIX = "`+d.Canonical.Prefix+`"`, ".slice(PREFIX.length)") {
		t.Errorf("F6: normalize fn missing the tenant-prefix suffix strip (PREFIX=%q + .slice):\n%s",
			d.Canonical.Prefix, body)
	}
}

// TestReaderContractEndToEnd is THE test — the one that would have caught all three
// CPACK regressions at once. It builds the exact envelope the reader emits for a set
// of sample PLC readings drawn from the descriptor's plc: tag maps, decodes it the way
// the agent does, and proves every tag resolves against the agent's suffix-keyed map.
func TestReaderContractEndToEnd(t *testing.T) {
	d, err := Parse([]byte(readerDescriptorYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	prefix := d.Canonical.Prefix // "CPACK/SC"

	// The agent tag map is synthesized from the SAME descriptor (GenerateAgentConfig),
	// keyed by metric SUFFIX — exactly what the runtime resolver consults.
	cfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}
	tagMap := cfg.TagMap()
	if len(tagMap) == 0 {
		t.Fatal("agent tag map is empty — nothing to resolve against")
	}

	// Sample readings, drawn from the descriptor's real plc: tag maps. Deliberately a
	// mix: at least one COUNTER leaf (/Admin/ProdProcessedCount/<idx>/Unit) and one
	// NON-counter (/Status/MachSpeed), across all three protocols (S7/OPC-UA/Modbus).
	readings := []sampleReading{
		{"CPACK/SC/LINHAS/L8/DXL", "/Status/MachSpeed", 12.5},                  // S7, non-counter
		{"CPACK/SC/LINHAS/L8/DXL", "/Admin/ProdProcessedCount/219/Unit", 4200}, // S7, counter
		{"CPACK/SC/CELULA9/FLEXO", "/Admin/ProdProcessedCount/557/Unit", 8800}, // OPC-UA, counter
		{"CPACK/SC/LINHAS/L6/PLC", "/Admin/ProdProcessedCount/600/Unit", 1500}, // Modbus, counter
	}
	total := len(readings)

	// Build the envelope EXACTLY as the reader does: the source node carries the FULL
	// canonical topic (packml_topic + metric), and the normalize fn strips the tenant
	// prefix to the suffix key (F6). We derive the suffix the same way here.
	env := wireEnvelope{Endpoint: "cpack-edge", ScanTS: 1782849957000}
	for _, r := range readings {
		full := r.packmlTopic + r.metric
		suffix := strings.TrimPrefix(full, prefix)
		if suffix == full {
			t.Fatalf("reading %q does not start with the canonical prefix %q — fixture bug", full, prefix)
		}
		env.Tags = append(env.Tags, wireTag{Metric: suffix, Value: r.value, TS: env.ScanTS})
	}
	body, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}

	// F5 — the agent decodes the envelope to exactly `total` tags (not zero).
	tags, err := rawtag.Decode(body)
	if err != nil {
		t.Fatalf("rawtag.Decode of the reader envelope failed: %v", err)
	}
	if len(tags) != total {
		t.Fatalf("F5: decoded %d tags, want %d — envelope shape broke", len(tags), total)
	}

	// F6 — every decoded metric resolves against the suffix-keyed tag map.
	accepted := 0
	for _, tag := range tags {
		if _, ok := tagMap[tag.Metric]; ok {
			accepted++
		} else {
			t.Errorf("F6: metric %q NOT in the agent tag map — would be dropped as unmapped", tag.Metric)
		}
	}
	// THE contract: every tag the reader emits both decodes and resolves.
	if accepted != total {
		t.Fatalf("CONTRACT VIOLATED: accepted=%d, total=%d — the reader emits tags the agent drops", accepted, total)
	}

	// --- Negative sub-case F5: the OLD envelope shape decodes to ZERO tags. ---
	// { timestamp, gateway, metrics:[{name,…}] } has no "tags" key, so rawtag.Decode
	// returns an empty slice — every reading silently discarded. This is the exact
	// failure the positive case guards against; proving it here shows the test has teeth.
	oldShape := []byte(`{
	  "timestamp": 1782849957000,
	  "gateway": "cpack-edge",
	  "metrics": [
	    {"name": "CPACK/SC/LINHAS/L8/DXL/Status/MachSpeed", "value": 12.5},
	    {"name": "CPACK/SC/LINHAS/L8/DXL/Admin/ProdProcessedCount/219/Unit", "value": 4200}
	  ]
	}`)
	oldTags, err := rawtag.Decode(oldShape)
	if err != nil {
		t.Fatalf("decode old-shape envelope errored (expected clean empty decode): %v", err)
	}
	if len(oldTags) != 0 {
		t.Errorf("F5 negative: old { gateway, metrics[] } shape decoded to %d tags, want 0 "+
			"(the test would NOT have caught F5)", len(oldTags))
	}

	// --- Negative sub-case F6: a FULL-CANONICAL metric resolves to ZERO. ---
	// Same readings, but metric = the full topic (prefix NOT stripped). It decodes
	// fine (F5 holds) but resolves against NOTHING — the live accepted:0 bug.
	fullEnv := wireEnvelope{Endpoint: "cpack-edge", ScanTS: 1782849957000}
	for _, r := range readings {
		fullEnv.Tags = append(fullEnv.Tags, wireTag{Metric: r.packmlTopic + r.metric, Value: r.value, TS: fullEnv.ScanTS})
	}
	fullBody, err := json.Marshal(fullEnv)
	if err != nil {
		t.Fatalf("marshal full-canonical envelope: %v", err)
	}
	fullTags, err := rawtag.Decode(fullBody)
	if err != nil {
		t.Fatalf("decode full-canonical envelope: %v", err)
	}
	if len(fullTags) != total {
		t.Fatalf("F6 negative: full-canonical envelope should still DECODE to %d tags, got %d", total, len(fullTags))
	}
	fullAccepted := 0
	for _, tag := range fullTags {
		if _, ok := tagMap[tag.Metric]; ok {
			fullAccepted++
		}
	}
	if fullAccepted != 0 {
		t.Errorf("F6 negative: full-canonical metrics resolved %d/%d — the map is NOT suffix-keyed "+
			"(the test would NOT have caught F6)", fullAccepted, total)
	}
}
