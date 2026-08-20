package clientdescriptor

import (
	"encoding/json"
	"strings"
	"testing"
)

// readerDescriptorYAML is a descriptor carrying a full three-protocol `plc:` block
// (the #684 DescriptorPLC schema) — one S7 endpoint (two count tags), one OPC-UA
// endpoint (one node), one Modbus endpoint (one register). The tag metrics are
// authored to line up with the metrics the equipment templates synthesize, so the
// descriptor passes the ADR-0045 §C client⇄agent consistency check (GenerateClientYAML
// runs inside Validate) — i.e. this is a REAL, valid descriptor, and the reader flow
// is generated off the same block the Go reader's client.yaml is. The S7 address
// shape (db/offset/type → DB1,DINT0) mirrors CPACK's real cpack.plc.yaml capture.
const readerDescriptorYAML = `
tenant: CPACK
enterprise_id: 3
canonical:
  prefix: CPACK/SC
mapping:
  count_index_default_mode: equipment_id
metric_templates:
  member:
    - {leaf: "/Status/MachSpeed", type: double}
    - {leaf: "/Admin/ProdProcessedCount/{idx}/Unit", type: double}
agent:
  edge_node_id: cpack-edge
  internal_broker: tcp://mosquitto:1883
  uplink_broker: tcp://ingest:1883
tee:
  ingest_url: https://localhost:8444/v1/tags
equipment:
  - topic: CPACK/SC/LINHAS/L8/DXL
    id_equipment: 8001
    tp_equipment: 1
    id_unit: 8001
    count_index: {value: 219, confidence: confirmed}
  - topic: CPACK/SC/CELULA9/FLEXO
    id_equipment: 8002
    tp_equipment: 1
    id_unit: 8002
    count_index: {value: 557, confidence: confirmed}
  - topic: CPACK/SC/LINHAS/L6/PLC
    id_equipment: 8003
    tp_equipment: 1
    id_unit: 8003
    count_index: {value: 600, confidence: confirmed}
plc:
  endpoints:
    - name: "S7 S8"
      protocol: s7
      host_ref: "secret://packiot/staging/cpack/s7-s8-host"
      rack: 0
      slot: 2
      polling_interval: 30s
    - name: "OPC L9"
      protocol: opcua
      endpoint_url_ref: "secret://packiot/staging/cpack/opc-l9-url"
    - name: "PLC_L6"
      protocol: modbus_tcp
      host_ref: "secret://packiot/staging/cpack/l6-host"
      unit_id: 1
  s7_tag_map:
    - endpoint: "S7 S8"
      packml_topic: CPACK/SC/LINHAS/L8/DXL
      id_equipment: 8001
      tags:
        - {metric: "/Status/MachSpeed", db: 1, offset: 8, type: real}
        - {metric: "/Admin/ProdProcessedCount/219/Unit", db: 1, offset: 0, type: dint}
  opcua_tag_map:
    - endpoint: "OPC L9"
      packml_topic: CPACK/SC/CELULA9/FLEXO
      id_equipment: 8002
      tags:
        - {metric: "/Admin/ProdProcessedCount/557/Unit", node_id: "ns=6;s=::OPCUAData:totalMeterCounter", type: float}
  modbus_tag_map:
    - endpoint: "PLC_L6"
      packml_topic: CPACK/SC/LINHAS/L6/PLC
      id_equipment: 8003
      tags:
        - {metric: "/Admin/ProdProcessedCount/600/Unit", kind: holding, address: 0, type: uint32}
`

// readerNoPLCDescriptorYAML is a minimal valid descriptor with NO plc block — the
// negative fixture for the "gates on d.PLC" test.
const readerNoPLCDescriptorYAML = `
tenant: NOPLC
enterprise_id: 1
canonical:
  prefix: NOPLC/SP
mapping:
  count_index_default_mode: equipment_id
metric_templates:
  member:
    - {leaf: "/Status/MachSpeed", type: double}
agent:
  edge_node_id: noplc-edge
  internal_broker: tcp://mosquitto:1883
  uplink_broker: tcp://ingest:1883
tee:
  ingest_url: https://localhost:8444/v1/tags
equipment:
  - topic: NOPLC/SP/LINE1/M1
    id_equipment: 1
    tp_equipment: 1
    id_unit: 1
`

// TestGeneratePlcReaderFlow parses a real three-protocol descriptor and asserts the
// generated Node-RED flow is well-formed and maps the descriptor's `plc:` block —
// the SAME block GenerateClientYAML consumes — into the right nodes: S7 vartables
// carrying full canonical-topic variable names, ${PLC_HOST_*} env hosts (no baked
// secrets), one OpcUa-Item per opcua tag, a modbus-read carrying its canonical topic,
// a normalize function, an http-request POST, and a customizations tab.
func TestGeneratePlcReaderFlow(t *testing.T) {
	d, err := Parse([]byte(readerDescriptorYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	out, err := d.GeneratePlcReaderFlow()
	if err != nil {
		t.Fatalf("GeneratePlcReaderFlow: %v", err)
	}

	// 1. Valid JSON array of node objects.
	var nodes []map[string]any
	if err := json.Unmarshal(out, &nodes); err != nil {
		t.Fatalf("generated flow is not a JSON array: %v\n%s", err, out)
	}
	if len(nodes) == 0 {
		t.Fatal("generated flow has no nodes")
	}

	byType := map[string][]map[string]any{}
	for _, n := range nodes {
		typ, _ := n["type"].(string)
		byType[typ] = append(byType[typ], n)
	}

	// 2. One node of each expected protocol + the plumbing must be present.
	for _, want := range []string{"tab", "s7 endpoint", "s7 in", "OpcUa-Endpoint", "OpcUa-Client", "OpcUa-Item", "modbus-client", "modbus-read", "function", "http request", "switch"} {
		if len(byType[want]) == 0 {
			t.Errorf("generated flow has no %q node", want)
		}
	}

	// 3. Two tabs: the reader tab AND the first-class customizations tab.
	if got := len(byType["tab"]); got != 2 {
		t.Errorf("tab count = %d, want 2 (reader + customizations)", got)
	}
	var hasCust bool
	for _, tab := range byType["tab"] {
		if tab["label"] == "CPACK customizations" {
			hasCust = true
		}
	}
	if !hasCust {
		t.Error("no 'CPACK customizations' tab")
	}

	// 4. The S7 endpoint host must be an env reference (NOT the secret value), and
	//    its vartable entries must carry FULL canonical-topic variable names + addr
	//    built from db/offset/type.
	s7ep := byType["s7 endpoint"][0]
	if host, _ := s7ep["address"].(string); host != "${PLC_HOST_S7_S8}" {
		t.Errorf("s7 endpoint address = %q, want ${PLC_HOST_S7_S8} (env-driven host)", host)
	}
	if s7ep["cycletime"] != "30000" {
		t.Errorf("s7 endpoint cycletime = %v, want 30000 (from polling_interval 30s)", s7ep["cycletime"])
	}
	vartable, ok := s7ep["vartable"].([]any)
	if !ok || len(vartable) != 2 {
		t.Fatalf("s7 vartable length = %d, want 2: %v", len(vartable), s7ep["vartable"])
	}
	var sawCanonicalCount bool
	for _, ve := range vartable {
		entry, _ := ve.(map[string]any)
		name, _ := entry["name"].(string)
		if name == "CPACK/SC/LINHAS/L8/DXL/Admin/ProdProcessedCount/219/Unit" {
			sawCanonicalCount = true
			if entry["addr"] != "DB1,DINT0" {
				t.Errorf("count tag addr = %v, want DB1,DINT0 (db1/offset0/dint)", entry["addr"])
			}
		}
		for _, k := range []string{"addr", "name", "type"} {
			if _, ok := entry[k]; !ok {
				t.Errorf("s7 vartable entry missing %q: %v", k, entry)
			}
		}
	}
	if !sawCanonicalCount {
		t.Error("s7 vartable has no entry named with the full canonical count topic")
	}

	// 5. OPC-UA: endpoint host is an env ref, and the item carries the nodeId as
	//    `item` and the canonical topic as `name`.
	opcEp := byType["OpcUa-Endpoint"][0]
	if opcEp["endpoint"] != "${PLC_HOST_OPC_L9}" {
		t.Errorf("OpcUa-Endpoint endpoint = %v, want ${PLC_HOST_OPC_L9}", opcEp["endpoint"])
	}
	item := byType["OpcUa-Item"][0]
	if item["item"] != "ns=6;s=::OPCUAData:totalMeterCounter" {
		t.Errorf("OpcUa-Item item = %v, want the opcua node_id", item["item"])
	}
	if item["name"] != "CPACK/SC/CELULA9/FLEXO/Admin/ProdProcessedCount/557/Unit" {
		t.Errorf("OpcUa-Item name = %v, want the full canonical topic", item["name"])
	}

	// 6. Modbus: client host is an env ref, and the read carries its canonical topic.
	mb := byType["modbus-client"][0]
	if mb["tcpHost"] != "${PLC_HOST_PLC_L6}" {
		t.Errorf("modbus-client tcpHost = %v, want ${PLC_HOST_PLC_L6}", mb["tcpHost"])
	}
	if mb["tcpPort"] != "502" {
		t.Errorf("modbus-client tcpPort = %v, want 502", mb["tcpPort"])
	}
	mr := byType["modbus-read"][0]
	if mr["topic"] != "CPACK/SC/LINHAS/L6/PLC/Admin/ProdProcessedCount/600/Unit" {
		t.Errorf("modbus-read topic = %v, want the full canonical topic", mr["topic"])
	}

	// 7. The normalize function reads the agent URL + ingest key from env, strips the
	//    tenant prefix to the canonical SUFFIX (matching the agent's raw_tag_map key),
	//    and emits the rawtag envelope { endpoint, scan_ts, tags[{metric,value,ts}] }
	//    with the X-Ingest-Key auth header. http POST has an empty url so the fn's
	//    msg.url from env wins.
	fn := byType["function"][0]
	body, _ := fn["func"].(string)
	// Rawtag envelope + ingest auth + URL wiring.
	if !containsAll(body, "CPACK_AGENT_URL", defaultAgentURL, "AGENT_INGEST_API_KEY",
		"X-Ingest-Key", "scan_ts", "tags", "metric") {
		t.Errorf("normalize function body missing expected rawtag/auth wiring:\n%s", body)
	}
	// It must NOT emit the OLD (wrong) envelope the agent's /v1/tags rejected.
	for _, bad := range []string{"gateway:", "metrics:"} {
		if strings.Contains(body, bad) {
			t.Errorf("normalize function still emits the old envelope token %q — agent rejects it:\n%s", bad, body)
		}
	}
	// Prefix strip: the SUFFIX key must be derived from the tenant prefix (CPACK/SC),
	// otherwise every tag is dropped unmapped by the agent (the live accepted:0 bug).
	if !containsAll(body, `PREFIX = "CPACK/SC"`, ".slice(PREFIX.length)") {
		t.Errorf("normalize function body missing the tenant-prefix suffix strip:\n%s", body)
	}
	httpReq := byType["http request"][0]
	if httpReq["method"] != "POST" {
		t.Errorf("http request method = %v, want POST", httpReq["method"])
	}
	if httpReq["url"] != "" {
		t.Errorf("http request url = %q, want empty (env-driven via msg.url)", httpReq["url"])
	}

	// 8. No baked secret must leak into the flow JSON.
	if strings.Contains(string(out), "secret://") {
		t.Errorf("generated flow leaked a secret:// reference — hosts must be env vars")
	}
}

// TestGeneratePlcReaderFlowNoPLC confirms a descriptor without a plc block yields an
// error (Generate gates on d.PLC before calling), never a bogus empty flow.
func TestGeneratePlcReaderFlowNoPLC(t *testing.T) {
	d, err := Parse([]byte(readerNoPLCDescriptorYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if d.PLC != nil {
		t.Fatal("fixture unexpectedly has a plc block")
	}
	if _, err := d.GeneratePlcReaderFlow(); err == nil {
		t.Fatal("expected an error for a descriptor with no plc block, got nil")
	}
}

// customizationsYAML is a two-node customizations block: one FLOW node (carrying a
// "z" that points at a DIFFERENT tab — as a real Node-RED export would) and one
// CONFIG node (no "z"). Appended to readerDescriptorYAML it exercises the ADR-0045
// G3 descriptor-sourced customizations surface.
const customizationsYAML = `
customizations:
  - id: cpack_cust_po_hook
    type: function
    z: some_exported_tab_id
    name: PO hook
    func: "return msg;"
    wires: [[]]
  - id: cpack_cust_broker
    type: mqtt-broker
    name: extra broker
    broker: 127.0.0.1
    port: 1883
`

// TestGeneratePlcReaderFlowCustomizations proves the descriptor's `customizations`
// block is rendered onto the customizations tab: a FLOW node is re-homed onto that
// tab (its "z" rewritten to the generated cust-tab id, regardless of the tab it was
// exported from), while a CONFIG node (no "z") passes through untouched. This is the
// mechanism that makes the customization surface descriptor-sourced + versioned
// instead of hand-added on the box.
func TestGeneratePlcReaderFlowCustomizations(t *testing.T) {
	d, err := Parse([]byte(readerDescriptorYAML + customizationsYAML))
	if err != nil {
		t.Fatalf("Parse (with customizations): %v", err)
	}
	out, err := d.GeneratePlcReaderFlow()
	if err != nil {
		t.Fatalf("GeneratePlcReaderFlow: %v", err)
	}
	var nodes []map[string]any
	if err := json.Unmarshal(out, &nodes); err != nil {
		t.Fatalf("generated flow is not a JSON array: %v", err)
	}
	byID := map[string]map[string]any{}
	tabs := 0
	for _, n := range nodes {
		if id, _ := n["id"].(string); id != "" {
			byID[id] = n
		}
		if n["type"] == "tab" {
			tabs++
		}
	}
	// Still exactly two tabs — customizations render ONTO the existing cust tab, they
	// do not add tabs of their own.
	if tabs != 2 {
		t.Errorf("tab count = %d, want 2 (customizations must not add tabs)", tabs)
	}
	// The flow node is present and re-homed onto the customizations tab (cpack_cust_tab).
	fn := byID["cpack_cust_po_hook"]
	if fn == nil {
		t.Fatal("customization flow node cpack_cust_po_hook missing from generated flow")
	}
	if fn["z"] != "cpack_cust_tab" {
		t.Errorf("customization flow node z = %v, want cpack_cust_tab (re-homed onto the cust tab)", fn["z"])
	}
	if fn["type"] != "function" || fn["name"] != "PO hook" {
		t.Errorf("customization flow node body not preserved: %v", fn)
	}
	// The config node is present and UNTOUCHED (no "z" added — config nodes are tab-less).
	cfg := byID["cpack_cust_broker"]
	if cfg == nil {
		t.Fatal("customization config node cpack_cust_broker missing from generated flow")
	}
	if _, hasZ := cfg["z"]; hasZ {
		t.Errorf("config node must not gain a z (it is tab-less): %v", cfg)
	}
}

// TestGeneratePlcReaderFlowCustomizationIDCollision proves a customization node whose
// id collides with a GENERATED reader node id fails closed — Node-RED silently breaks
// a flow with duplicate ids, so the generator refuses rather than emit it.
func TestGeneratePlcReaderFlowCustomizationIDCollision(t *testing.T) {
	// cpack_reader_norm is the generated normalize function id (p + "_reader_norm").
	collide := `
customizations:
  - id: cpack_reader_norm
    type: function
    z: t
    func: "return msg;"
`
	d, err := Parse([]byte(readerDescriptorYAML + collide))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if _, err := d.GeneratePlcReaderFlow(); err == nil {
		t.Fatal("expected a collision error for a customization id that duplicates a reader node id, got nil")
	}
}

// TestDescriptorCustomizationValidation proves the descriptor-time structural check:
// a customization node missing the required id/type strings, or duplicating an id, is
// rejected by Validate (via Parse) — a malformed paste fails at author time.
func TestDescriptorCustomizationValidation(t *testing.T) {
	cases := map[string]string{
		"missing type": "\ncustomizations:\n  - id: only_id\n    name: no type\n",
		"missing id":   "\ncustomizations:\n  - type: function\n    name: no id\n",
		"dup id":       "\ncustomizations:\n  - {id: dup, type: function}\n  - {id: dup, type: comment}\n",
	}
	for name, block := range cases {
		if _, err := Parse([]byte(readerDescriptorYAML + block)); err == nil {
			t.Errorf("%s: expected Parse to reject the customization, got nil", name)
		}
	}
}

// TestDescriptorLiteralHostRefAccepted proves the F9 relaxation on the DESCRIPTOR
// surface (onboard-gen): a literal PLC host_ref / endpoint_url_ref passes Parse
// (which runs Validate → validatePLC), so a DB descriptor can carry literal hosts
// and onboard-gen no longer rejects them. This is the same shape GenerateClientYAML
// copies into client.yaml — kept consistent by reusing clientconfig.IsLiteralHost.
func TestDescriptorLiteralHostRefAccepted(t *testing.T) {
	body := strings.ReplaceAll(readerDescriptorYAML,
		`host_ref: "secret://packiot/staging/cpack/s7-s8-host"`, `host_ref: "10.135.1.128:102"`)
	body = strings.ReplaceAll(body,
		`endpoint_url_ref: "secret://packiot/staging/cpack/opc-l9-url"`, `endpoint_url_ref: "opc.tcp://10.135.6.169:4840"`)
	body = strings.ReplaceAll(body,
		`host_ref: "secret://packiot/staging/cpack/l6-host"`, `host_ref: "10.135.1.130"`)
	d, err := Parse([]byte(body))
	if err != nil {
		t.Fatalf("descriptor with literal hosts must Parse: %v", err)
	}
	if d.PLC.Endpoints[0].HostRef != "10.135.1.128:102" ||
		d.PLC.Endpoints[1].EndpointURLRef != "opc.tcp://10.135.6.169:4840" ||
		d.PLC.Endpoints[2].HostRef != "10.135.1.130" {
		t.Fatalf("literal hosts not parsed through: %+v", d.PLC.Endpoints)
	}
}

// TestDescriptorHostRefRejectsGarbage keeps the guard on the descriptor surface:
// a value that is neither a host, a secret:// ref, nor empty still fails Validate.
func TestDescriptorHostRefRejectsGarbage(t *testing.T) {
	body := strings.ReplaceAll(readerDescriptorYAML,
		`host_ref: "secret://packiot/staging/cpack/s7-s8-host"`, `host_ref: "http://nope/../etc"`)
	if _, err := Parse([]byte(body)); err == nil ||
		!strings.Contains(err.Error(), "must be empty, a secret:// reference, or a literal host[:port]") {
		t.Fatalf("want literal-host rejection, got %v", err)
	}
}

func containsAll(s string, subs ...string) bool {
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			return false
		}
	}
	return true
}
