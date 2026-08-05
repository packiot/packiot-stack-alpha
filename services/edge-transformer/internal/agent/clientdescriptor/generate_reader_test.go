package clientdescriptor

import (
	"encoding/json"
	"strings"
	"testing"
)

// cpackPlcYAML is docs/clients/cpack.plc.yaml embedded verbatim: the REAL CPACK PLC
// block extracted read-only from the live CPACK Node-RED (9 S7 + 1 OPC-UA + 4
// Modbus, 86 tags). It is embedded rather than read from disk so the test is
// self-contained (the file lives in the docs/ tree, not this module) and
// deterministic. If cpack.plc.yaml changes, update this fixture to match.
const cpackPlcYAML = `
tenant: CPACK
enterprise_id: 3
plc:
  - protocol: s7
    name: "S7 115"
    endpoint: 10.135.16.115
    rack: 0
    slot: 2
    poll_ms: 15000
    tags:
      - { name: 514, address: "DB1,DINT0" }
      - { name: 515, address: "DB1,DINT4" }
      - { name: 516, address: "DB1,DINT8" }
      - { name: 606, address: "DB1,INT48" }
  - protocol: s7
    name: "S7 S8"
    endpoint: 10.135.16.26
    rack: 0
    slot: 2
    poll_ms: 30000
    tags:
      - { name: "C-PACK/SC/LINHAS/L8/DXL/Admin/ProdProcessedCount/219/Unit***TRIG_C=I", address: "DB1,DINT0" }
      - { name: PTH_COUNT_OK, address: "DB1,DINT4" }
      - { name: "C-PACK/SC/LINHAS/L8/PTH/Admin/ProdConsumedCount/220/Unit***TRIG_C=O", address: "DB1,INT32" }
      - { name: 19S, address: "DB1,X1024.7" }
      - { name: VERSION, address: "DB1,INT48" }
  - protocol: opcua
    endpoint: "opc.tcp://10.135.6.169:4840"
    tags:
      - { name: "C-PACK/SC/CELULA9/FLEXO/FLEXO/Admin/ProdConsumedCount/557/Unit***TRIG_C=O", address: "ns=6;s=::OPCUAData:totalMeterCounter" }
      - { name: "C-PACK/SC/CELULA9/FLEXO/FLEXO/Status/CurMachSpeed", address: "ns=6;s=::OPCUAData:actualSpeed" }
  - protocol: modbus_tcp
    name: PLC_L6
    endpoint: "10.135.1.128:502"
    unit: 1
  - protocol: modbus_tcp
    name: PLC_L5
    endpoint: "10.135.1.125:502"
    unit: 1
`

// TestGeneratePlcReaderFlow loads the CPACK PLC-reader fixture through the package's
// own Parse path and asserts the generated Node-RED flow is well-formed and carries
// the right node of each protocol — the autonomous-edge artifact the ADR-0045
// onboarding needs so a greenfield client's bundle brings its OWN PLC reader.
func TestGeneratePlcReaderFlow(t *testing.T) {
	doc, err := ParsePlcReader([]byte(cpackPlcYAML))
	if err != nil {
		t.Fatalf("ParsePlcReader: %v", err)
	}

	out, err := doc.GeneratePlcReaderFlow()
	if err != nil {
		t.Fatalf("GeneratePlcReaderFlow: %v", err)
	}

	// 1. It must be a valid JSON array of node objects.
	var nodes []map[string]any
	if err := json.Unmarshal(out, &nodes); err != nil {
		t.Fatalf("generated flow is not a JSON array: %v\n%s", err, out)
	}
	if len(nodes) == 0 {
		t.Fatal("generated flow has no nodes")
	}

	// 2. Index the nodes by type for the presence assertions.
	byType := map[string][]map[string]any{}
	for _, n := range nodes {
		typ, _ := n["type"].(string)
		byType[typ] = append(byType[typ], n)
	}

	for _, want := range []string{"tab", "s7 endpoint", "s7 in", "OpcUa-Endpoint", "OpcUa-Client", "OpcUa-Item", "modbus-client", "modbus-read", "function", "http request", "switch"} {
		if len(byType[want]) == 0 {
			t.Errorf("generated flow has no %q node", want)
		}
	}

	// Two S7 connections in the fixture → two s7 endpoint + two s7 in nodes.
	if got := len(byType["s7 endpoint"]); got != 2 {
		t.Errorf("s7 endpoint node count = %d, want 2", got)
	}
	// Two Modbus connections → two modbus-client + two modbus-read nodes.
	if got := len(byType["modbus-client"]); got != 2 {
		t.Errorf("modbus-client node count = %d, want 2", got)
	}

	// 3. The first S7 endpoint must carry the real factory-LAN address and a
	//    non-empty vartable whose entries carry addr/name/type.
	var ep115 map[string]any
	for _, ep := range byType["s7 endpoint"] {
		if ep["address"] == "10.135.16.115" {
			ep115 = ep
			break
		}
	}
	if ep115 == nil {
		t.Fatal("no s7 endpoint with address 10.135.16.115")
	}
	if ep115["cycletime"] != "15000" {
		t.Errorf("s7 endpoint 115 cycletime = %v, want 15000 (from poll_ms)", ep115["cycletime"])
	}
	vartable, ok := ep115["vartable"].([]any)
	if !ok || len(vartable) == 0 {
		t.Fatalf("s7 endpoint 115 vartable is empty or wrong type: %v", ep115["vartable"])
	}
	first, _ := vartable[0].(map[string]any)
	for _, k := range []string{"addr", "name", "type"} {
		if _, ok := first[k]; !ok {
			t.Errorf("s7 vartable entry missing %q field: %v", k, first)
		}
	}

	// 4. The OPC-UA endpoint must carry the fixture's opc.tcp URL, and there must be
	//    one OpcUa-Item per opcua tag (2 in the fixture).
	if url := byType["OpcUa-Endpoint"][0]["endpoint"]; url != "opc.tcp://10.135.6.169:4840" {
		t.Errorf("OpcUa-Endpoint endpoint = %v, want opc.tcp://10.135.6.169:4840", url)
	}
	if got := len(byType["OpcUa-Item"]); got != 2 {
		t.Errorf("OpcUa-Item node count = %d, want 2", got)
	}

	// 5. A Modbus client must split host:port and carry the unit id.
	var mbL6 map[string]any
	for _, mc := range byType["modbus-client"] {
		if mc["name"] == "PLC_L6" {
			mbL6 = mc
			break
		}
	}
	if mbL6 == nil {
		t.Fatal("no modbus-client named PLC_L6")
	}
	if mbL6["tcpHost"] != "10.135.1.128" || mbL6["tcpPort"] != "502" {
		t.Errorf("modbus-client PLC_L6 host:port = %v:%v, want 10.135.1.128:502", mbL6["tcpHost"], mbL6["tcpPort"])
	}

	// 6. The normalize function must read the agent URL env + reference the default
	//    sparkplug-agent ingest, and the http request must be a POST with an empty
	//    url (so the fn's msg.url from env wins).
	fn := byType["function"][0]
	body, _ := fn["func"].(string)
	if !containsAll(body, "CPACK_AGENT_URL", defaultAgentURL, "metrics") {
		t.Errorf("normalize function body missing expected wiring:\n%s", body)
	}
	httpReq := byType["http request"][0]
	if httpReq["method"] != "POST" {
		t.Errorf("http request method = %v, want POST", httpReq["method"])
	}
	if httpReq["url"] != "" {
		t.Errorf("http request url = %q, want empty (env-driven via msg.url)", httpReq["url"])
	}
}

// TestParsePlcReaderRejectsBadProtocol confirms validation fails closed on an
// unknown protocol token rather than emitting a flow with an unrecognised source.
func TestParsePlcReaderRejectsBadProtocol(t *testing.T) {
	const bad = `
tenant: X
enterprise_id: 1
plc:
  - protocol: bacnet
    endpoint: 10.0.0.1
`
	if _, err := ParsePlcReader([]byte(bad)); err == nil {
		t.Fatal("expected an error for an unknown protocol, got nil")
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
