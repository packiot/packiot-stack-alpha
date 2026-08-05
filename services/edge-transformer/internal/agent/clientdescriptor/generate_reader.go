package clientdescriptor

// generate_reader.go closes the last gap in the ADR-0045 config-as-data onboarding
// story: the AUTONOMOUS (self-contained) edge.
//
// GenerateTeeSnippet (generate.go, artifact 4) emits only a *tee* — a second wire
// off an EXISTING SparkPlug-assembly node the client already runs. That assumes a
// factory whose Node-RED already reads its PLCs. A greenfield client onboarded from
// CS-Admin has no such flow: the descriptor is the ONLY thing authored, so the
// generated bundle must also bring its OWN PLC reader.
//
// This file turns a descriptor's `plc:` block — one entry per reachable PLC, each
// with its S7/OPC-UA/Modbus addressing and the raw tags to poll — into a runnable
// Node-RED flow: protocol input nodes (node-red-contrib-s7 / -opcua / -modbus)
// → a shared normalize `function` → an `http request` that POSTs the raw
// { timestamp, gateway, metrics[] } envelope to the LOCAL sparkplug-agent HTTP
// ingest (:9104/v1/tags). The agent then does the real work — canonical mapping,
// numeric count-index routing, SparkPlug-B birth/data — exactly as it does for the
// tee. So the reader is a dumb producer of raw named tags, and every per-tenant
// quirk still lives stack-side in the agent profile (ADR-0045 §2.3 Option B), never
// in the generated flow.
//
// Why a distinct parse type (PlcReaderDoc) and not the main Descriptor:
// the reader `plc:` block is a SEQUENCE of physical connections carrying INLINE
// factory-LAN addresses + {name,address} tags (see docs/clients/cpack.plc.yaml),
// a different shape from — and authored alongside — the main client descriptor
// (whose `plc:` key already binds the DescriptorPLC → Go-reader client.yaml path,
// #684). Keeping it a standalone document lets a CS engineer capture PLC wiring
// read-only from a live Node-RED (GET /admin/flows) into one file the generator
// consumes, without entangling it with the full descriptor's validation surface.

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// PlcReaderDoc is the parsed PLC-reader document — the SSoT for one tenant's edge
// PLC connectivity. It is authored (or captured from a live Node-RED) as a sibling
// to the main client descriptor: same tenant/enterprise, but carrying the physical
// connection + tag detail the generator turns into a Node-RED reader flow.
type PlcReaderDoc struct {
	// Tenant is the SparkPlug group_id / enterprise short-name, e.g. "CPACK". It
	// seeds the deterministic node-id prefix and the default gateway/env-var names.
	Tenant string `yaml:"tenant"`

	// EnterpriseID mirrors the descriptor's enterprise_id (informational here — the
	// reader emits raw tags; the agent owns enterprise scoping). Kept so the two
	// sibling documents are self-describing and cross-checkable.
	EnterpriseID int `yaml:"enterprise_id"`

	// Plc is the list of reachable PLCs, one entry per physical connection.
	Plc []PlcConn `yaml:"plc"`
}

// PlcConn is one reachable PLC and the raw tags to poll from it. Protocol selects
// which node-red-contrib palette drives it; the addressing fields are
// protocol-specific (Rack/Slot → S7, Unit → Modbus, Endpoint holds the OPC-UA URL
// or host[:port]).
type PlcConn struct {
	// Protocol ∈ {s7, opcua, modbus_tcp} — the same tokens the descriptor uses
	// (PLCProtocol* constants), so a tag map authored either side speaks one vocab.
	Protocol string `yaml:"protocol"`

	// Name is a human label (S7/Modbus). Empty is allowed (OPC-UA connections in the
	// wild often omit it); the generator falls back to the endpoint for the label.
	Name string `yaml:"name"`

	// Endpoint is the reachable address. For s7/modbus_tcp it is host or host:port
	// (10.135.16.115, 10.135.1.128:502); for opcua the full opc.tcp:// URL.
	Endpoint string `yaml:"endpoint"`

	// Rack/Slot are the S7 CPU rack/slot (default 0/… per the PLC).
	Rack int `yaml:"rack"`
	Slot int `yaml:"slot"`

	// PollMS is the poll cycle in milliseconds — the S7 endpoint cycletime, the
	// OPC-UA read tick, the Modbus read rate. 0 ⇒ a protocol-sensible default.
	PollMS int `yaml:"poll_ms"`

	// Unit is the Modbus unit_id (slave address). Ignored for s7/opcua.
	Unit int `yaml:"unit"`

	// Tags are the raw tags to read. Each tag's Name is the CANONICAL topic (or a
	// numeric count index the agent's numeric routing resolves); Address is the
	// protocol-native address (S7 "DB1,DINT0", OPC-UA node-id "ns=6;s=…").
	Tags []PlcTag `yaml:"tags"`
}

// PlcTag is one raw tag to poll: Name is what goes on the wire as the metric name
// (a canonical topic or a numeric count index), Address is the physical location.
type PlcTag struct {
	Name    string `yaml:"name"`
	Address string `yaml:"address"`
}

// ParsePlcReader unmarshals + light-validates a PLC-reader document from raw bytes.
// It is the byte core LoadPlcReader wraps — so a document that arrives over the
// wire (the onboard API) is validated through the same path a file on disk is. JSON
// callers are handled transparently (JSON ⊂ YAML, same struct tags).
func ParsePlcReader(raw []byte) (*PlcReaderDoc, error) {
	var doc PlcReaderDoc
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("clientdescriptor: parse plc reader: %w", err)
	}
	if err := doc.validate(); err != nil {
		return nil, fmt.Errorf("clientdescriptor: validate plc reader: %w", err)
	}
	return &doc, nil
}

// LoadPlcReader reads + validates a PLC-reader document from disk, delegating the
// unmarshal + validation to ParsePlcReader so the file and wire paths share a core.
func LoadPlcReader(path string) (*PlcReaderDoc, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("clientdescriptor: read %s: %w", path, err)
	}
	doc, err := ParsePlcReader(raw)
	if err != nil {
		return nil, fmt.Errorf("clientdescriptor: %s: %w", path, err)
	}
	return doc, nil
}

// validate enforces the reader document's structural invariants BEFORE generation:
// a tenant, at least one connection, a known protocol per connection, a non-empty
// endpoint. Tag-level shape is intentionally permissive — a reader is a dumb
// producer, and the agent (not this flow) rejects tags it cannot resolve.
func (doc *PlcReaderDoc) validate() error {
	if strings.TrimSpace(doc.Tenant) == "" {
		return fmt.Errorf("tenant is required")
	}
	if len(doc.Plc) == 0 {
		return fmt.Errorf("plc must list at least one connection (nothing to read)")
	}
	for i, c := range doc.Plc {
		switch c.Protocol {
		case PLCProtocolS7, PLCProtocolOPCUA, PLCProtocolModbusTCP:
		default:
			return fmt.Errorf("plc[%d] (%s): protocol=%q must be %s|%s|%s",
				i, c.label(), c.Protocol, PLCProtocolS7, PLCProtocolOPCUA, PLCProtocolModbusTCP)
		}
		if strings.TrimSpace(c.Endpoint) == "" {
			return fmt.Errorf("plc[%d] (%s): endpoint is required", i, c.label())
		}
	}
	return nil
}

// label returns a stable human label for a connection — Name when set, else the
// endpoint. Used in errors + node names so a nameless OPC-UA connection still reads.
func (c PlcConn) label() string {
	if n := strings.TrimSpace(c.Name); n != "" {
		return n
	}
	return c.Endpoint
}

// GeneratePlcReaderFlow builds the Node-RED PLC-reader flow (the autonomous-edge
// artifact): one tab, protocol input nodes per connection, a shared normalize
// function, and an http-request POST to the local sparkplug-agent. It is a PURE
// function of the (validated) document, and node ids are DETERMINISTIC (derived
// from tenant + protocol + index) so regenerating the same document yields a
// byte-stable diff — the same discipline every ADR-0045 generator holds.
//
// Wire shape (left → right): each protocol source → the normalize function →
// http request → a statusCode switch → ok/err debug. S7 "all"-mode and Modbus
// reads self-drive on their cycle; OPC-UA reads are driven by a per-connection
// inject tick (the OPC-UA client is request/response, not a subscription here).
func (doc *PlcReaderDoc) GeneratePlcReaderFlow() ([]byte, error) {
	p := strings.ToLower(doc.Tenant) // node-id prefix + default gateway/env stems
	gateway := p + "-edge"
	urlEnv := strings.ToUpper(doc.Tenant) + "_AGENT_URL"

	tabID := p + "_reader_tab"
	fnID := p + "_reader_norm"
	httpID := p + "_reader_http"
	switchID := p + "_reader_route"
	okID := p + "_reader_ok"
	errID := p + "_reader_err"

	nodes := []map[string]any{
		{
			"id":       tabID,
			"type":     "tab",
			"label":    doc.Tenant + " PLC reader",
			"disabled": false,
			"info": "Generated from the ADR-0045 plc reader block (docs/clients/<tenant>.plc.yaml). " +
				"Reads the factory PLCs and POSTs raw named tags to the local sparkplug-agent " +
				"(default " + defaultAgentURL + ", override with env " + urlEnv + "). The agent does the " +
				"canonical mapping — this flow is a DUMB producer. Do not hand-edit; edit the plc doc + regenerate.",
		},
	}

	// yCursor lays flow nodes out top-to-bottom in the source column so a large
	// tenant (CPACK: 9 S7 + 1 OPC-UA + 4 Modbus) stays readable. Config nodes
	// (endpoints/clients) carry no x/y — Node-RED keeps them in the config drawer.
	const (
		xSource = 180
		xItem   = 380
		xClient = 580
		yStep   = 80
	)
	yCursor := 100

	for i, c := range doc.Plc {
		switch c.Protocol {
		case PLCProtocolS7:
			epID := fmt.Sprintf("%s_s7_%d_ep", p, i)
			inID := fmt.Sprintf("%s_s7_%d_in", p, i)
			nodes = append(nodes, s7EndpointNode(epID, c))
			nodes = append(nodes, map[string]any{
				"id": inID, "type": "s7 in", "z": tabID,
				"endpoint": epID, "mode": "all", "variable": "", "diff": false,
				"name": "read " + c.label(),
				"x":    xSource, "y": yCursor, "wires": []any{[]any{fnID}},
			})
			yCursor += yStep

		case PLCProtocolOPCUA:
			epID := fmt.Sprintf("%s_opcua_%d_ep", p, i)
			clientID := fmt.Sprintf("%s_opcua_%d_client", p, i)
			tickID := fmt.Sprintf("%s_opcua_%d_tick", p, i)
			nodes = append(nodes, opcuaEndpointNode(epID, c))
			// One inject tick drives every item of this connection; each item feeds
			// the client, which performs the read and emits value → normalize.
			itemIDs := make([]any, 0, len(c.Tags))
			itemY := yCursor
			for j, t := range c.Tags {
				itemID := fmt.Sprintf("%s_opcua_%d_item_%d", p, i, j)
				itemIDs = append(itemIDs, itemID)
				nodes = append(nodes, map[string]any{
					"id": itemID, "type": "OpcUa-Item", "z": tabID,
					"item": t.Address, "datatype": "Double", "value": "",
					"name": t.Name,
					"x":    xItem, "y": itemY, "wires": []any{[]any{clientID}},
				})
				itemY += yStep
			}
			nodes = append(nodes, map[string]any{
				"id": tickID, "type": "inject", "z": tabID,
				"name": "poll " + c.label(),
				"props": []any{map[string]any{"p": "payload"}},
				"repeat": strconv.Itoa(pollSeconds(c.PollMS, defaultOpcuaPollMS)), "crontab": "", "once": true, "onceDelay": "1",
				"topic": "", "payload": "", "payloadType": "date",
				"x": xSource, "y": yCursor, "wires": []any{itemIDs},
			})
			nodes = append(nodes, map[string]any{
				"id": clientID, "type": "OpcUa-Client", "z": tabID,
				"endpoint": epID, "action": "read", "deadbandtype": "a", "deadbandvalue": 1,
				"time": 10, "timeUnit": "s", "certificate": "n", "localfile": "", "localkeyfile": "",
				"securitymode": "None", "securitypolicy": "None", "folderName4PKI": "",
				"useTransport": false, "maxChunkCount": "", "maxMessageSize": "",
				"receiveBufferSize": "", "sendBufferSize": "",
				"name": "read " + c.label(),
				"x":    xClient, "y": yCursor, "wires": []any{[]any{fnID}},
			})
			if itemY > yCursor+yStep {
				yCursor = itemY
			} else {
				yCursor += yStep
			}

		case PLCProtocolModbusTCP:
			clientID := fmt.Sprintf("%s_mb_%d_client", p, i)
			readID := fmt.Sprintf("%s_mb_%d_read", p, i)
			host, port := splitHostPort(c.Endpoint, "502")
			nodes = append(nodes, modbusClientNode(clientID, c, host, port))
			nodes = append(nodes, map[string]any{
				"id": readID, "type": "modbus-read", "z": tabID,
				"name": "read " + c.label(), "topic": "",
				"showStatusActivities": false, "logIOActivities": false,
				"showErrors": false, "showWarnings": true,
				"unitid": strconv.Itoa(c.Unit), "dataType": "HoldingRegister",
				"adr": "0", "quantity": "1",
				"rate": strconv.Itoa(pollSeconds(c.PollMS, defaultModbusPollMS)), "rateUnit": "s",
				"delayOnStart": false, "startDelayTime": "",
				"server": clientID, "useIOFile": false, "ioFile": "",
				"useIOForPayload": false, "emptyMsgOnFail": false,
				"x": xSource, "y": yCursor, "wires": []any{[]any{fnID}, []any{}},
			})
			yCursor += yStep
		}
	}

	// Shared normalize function + POST chain. Placed to the right of the sources.
	midY := 100 + (len(nodes)*yStep)/6 // roughly centred on the source column
	nodes = append(nodes,
		map[string]any{
			"id": fnID, "type": "function", "z": tabID,
			"name":    doc.Tenant + " normalize → raw tags",
			"func":    readerFunctionBody(doc.Tenant, gateway, urlEnv),
			"outputs": 1, "noerr": 0, "initialize": "", "finalize": "", "libs": []any{},
			"x": 820, "y": midY, "wires": []any{[]any{httpID}},
		},
		map[string]any{
			"id": httpID, "type": "http request", "z": tabID,
			"name":   "POST → sparkplug-agent :9104",
			"method": "POST", "ret": "obj", "paytoqs": "ignore",
			// url left empty so the normalize fn's msg.url (from env) wins; the default
			// lives in the function, matching how the tee reads its ingest key from env.
			"url": "", "tls": "", "persist": false, "proxy": "",
			"insecureHTTPParser": false, "authType": "", "senderr": true,
			"headers": []any{},
			"x":       1040, "y": midY, "wires": []any{[]any{switchID}},
		},
		map[string]any{
			"id": switchID, "type": "switch", "z": tabID,
			"name": "statusCode", "property": "statusCode", "propertyType": "msg",
			"rules": []any{
				map[string]any{"t": "lt", "v": "300", "vt": "num"},
				map[string]any{"t": "else"},
			},
			"checkall": "false", "repair": false, "outputs": 2,
			"x": 1240, "y": midY, "wires": []any{[]any{okID}, []any{errID}},
		},
		map[string]any{
			"id": okID, "type": "debug", "z": tabID, "name": "2xx accepted",
			"active": true, "tosidebar": true, "console": false, "complete": "statusCode",
			"x": 1440, "y": midY - 40, "wires": []any{},
		},
		map[string]any{
			"id": errID, "type": "debug", "z": tabID, "name": "ingest error",
			"active": true, "tosidebar": true, "console": true, "complete": "payload",
			"x": 1440, "y": midY + 40, "wires": []any{},
		},
	)

	out, err := json.MarshalIndent(nodes, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal plc reader flow: %w", err)
	}
	return append(out, '\n'), nil
}

// defaultAgentURL is the local sparkplug-agent HTTP ingest the reader POSTs to. It
// is a Docker service name (sparkplug-agent) reachable inside the edge bundle's
// compose network — the same fix as the CPACK live-box bug (a localhost URL only
// worked from the host, not from the Node-RED container).
const defaultAgentURL = "http://sparkplug-agent:9104/v1/tags"

// Protocol poll defaults (ms) when a connection omits poll_ms.
const (
	defaultOpcuaPollMS  = 10000
	defaultModbusPollMS = 15000
	defaultS7PollMS     = 15000
)

// s7EndpointNode builds a node-red-contrib-s7 `s7 endpoint` config node. Field names
// + defaults are copied verbatim from the real CPACK flow so the palette recognises
// them; cycletime carries the poll interval and the vartable is built from Tags.
func s7EndpointNode(id string, c PlcConn) map[string]any {
	vartable := make([]any, 0, len(c.Tags))
	for _, t := range c.Tags {
		vartable = append(vartable, map[string]any{
			"addr": t.Address,
			"name": t.Name,
			"type": inferS7Type(t.Address),
		})
	}
	cycle := c.PollMS
	if cycle == 0 {
		cycle = defaultS7PollMS
	}
	return map[string]any{
		"id": id, "type": "s7 endpoint",
		"transport": "iso-on-tcp", "address": c.Endpoint, "port": "102",
		"rack": strconv.Itoa(c.Rack), "slot": strconv.Itoa(c.Slot),
		"localtsaphi": "01", "localtsaplo": "00",
		"remotetsaphi": "02", "remotetsaplo": "00",
		"connmode": "rack-slot", "adapter": "", "busaddr": strconv.Itoa(c.Slot),
		"cycletime": strconv.Itoa(cycle), "timeout": "1500",
		"name":     c.label(),
		"vartable": vartable,
	}
}

// opcuaEndpointNode builds a node-red-contrib-opcua `OpcUa-Endpoint` config node
// with anonymous, no-security defaults (secpol/secmode "None") — the shape the real
// CPACK OPC-UA connection uses. Security material is a deploy-time concern the CS
// engineer fills in on the endpoint, not something the generator invents.
func opcuaEndpointNode(id string, c PlcConn) map[string]any {
	return map[string]any{
		"id": id, "type": "OpcUa-Endpoint",
		"endpoint": c.Endpoint, "secpol": "None", "secmode": "None",
		"none": true, "login": false, "usercert": false,
		"usercertificate": "", "userprivatekey": "",
	}
}

// modbusClientNode builds a node-red-contrib-modbus `modbus-client` config node
// (TCP) from a split host:port and the connection's unit id. Serial fields carry
// the palette's harmless defaults so the node validates even though clienttype=tcp.
func modbusClientNode(id string, c PlcConn, host, port string) map[string]any {
	return map[string]any{
		"id": id, "type": "modbus-client",
		"name": c.label(), "clienttype": "tcp",
		"bufferCommands": true, "stateLogEnabled": false, "queueLogEnabled": false,
		"tcpHost": host, "tcpPort": port, "tcpType": "DEFAULT",
		"serialPort": "/dev/ttyUSB", "serialType": "RTU-BUFFERD",
		"serialBaudrate": "9600", "serialDatabits": "8", "serialStopbits": "1",
		"serialParity": "none", "serialConnectionDelay": "100",
		"unit_id": c.Unit, "commandDelay": 1, "clientTimeout": 1000,
		"reconnectOnTimeout": true, "reconnectTimeout": 30000,
		"parallelUnitIdsAllowed": false,
	}
}

// readerFunctionBody renders the shared normalize `function` node body. It reads the
// agent ingest URL from env (default defaultAgentURL), maps each incoming PLC read
// to a { name, value, timestamp } metric, and emits the same { timestamp, gateway,
// metrics[] } envelope teeFunctionBody produces — so the agent's ingest path is
// identical whether the raw tags came from a tee or from this own-reader flow.
//
// It handles the two source shapes this flow produces:
//   - S7 "all" mode → msg.payload is an OBJECT { varName: value, … }: one metric per
//     numeric entry (varName is the canonical topic or numeric count index).
//   - OPC-UA read → msg.payload is a scalar with msg.topic/name the tag identity.
//
// (Modbus reads emit register arrays with no per-tag names in this scaffold; they
// are skipped until the plc doc's modbus connections carry a tag map — the fn warns
// so the gap is visible rather than silent.)
func readerFunctionBody(tenant, gateway, urlEnv string) string {
	return "// " + tenant + " PLC reader → sparkplug-agent — generated from the ADR-0045 plc reader block.\n" +
		"// DUMB producer: emits raw named tags; the agent does the canonical mapping.\n" +
		"// Override the agent ingest URL with env " + urlEnv + " (default " + defaultAgentURL + ").\n" +
		"\n" +
		"const url = env.get(\"" + urlEnv + "\") || \"" + defaultAgentURL + "\";\n" +
		"const ts = Date.now();\n" +
		"const metrics = [];\n" +
		"const p = msg.payload;\n" +
		"if (p && typeof p === \"object\" && !Array.isArray(p)) {\n" +
		"    // S7 \"all\" mode: { varName: value, … } — one metric per numeric entry.\n" +
		"    for (const k of Object.keys(p)) {\n" +
		"        const v = p[k];\n" +
		"        if (typeof v === \"number\" && isFinite(v)) metrics.push({ name: k, value: v, timestamp: ts });\n" +
		"    }\n" +
		"} else if (typeof p === \"number\" && isFinite(p)) {\n" +
		"    // OPC-UA (or any scalar) read: identity is on msg.topic / msg.name.\n" +
		"    const name = msg.topic || msg.name;\n" +
		"    if (name) metrics.push({ name: name, value: p, timestamp: ts });\n" +
		"}\n" +
		"\n" +
		"if (metrics.length === 0) {\n" +
		"    node.warn(\"reader: no numeric tags in this message (modbus arrays need a tag map); skipping\");\n" +
		"    return null;\n" +
		"}\n" +
		"\n" +
		"msg.url = url;\n" +
		"msg.headers = { \"Content-Type\": \"application/json\" };\n" +
		"msg.payload = { timestamp: ts, gateway: \"" + gateway + "\", metrics: metrics };\n" +
		"return msg;\n"
}

// inferS7Type reads the S7 data-type token out of an address like "DB1,DINT0" →
// "DINT", "DB1,INT48" → "INT", "DB1,X1024.7" → "X" (bit), "DB1,WORD1118" → "WORD".
// node-red-contrib-s7 derives the real type from the addr string itself; the
// vartable `type` field is informational, so an unrecognised shape falls back to
// "DINT" (the dominant CPACK count type) rather than failing generation.
func inferS7Type(address string) string {
	// Take the substring after the last comma (the area+type+offset token), then
	// read the leading run of letters — that is the type mnemonic.
	tok := address
	if i := strings.LastIndex(address, ","); i >= 0 {
		tok = address[i+1:]
	}
	var b strings.Builder
	for _, r := range tok {
		if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') {
			b.WriteRune(r)
			continue
		}
		break
	}
	if t := strings.ToUpper(b.String()); t != "" {
		return t
	}
	return "DINT"
}

// pollSeconds converts a poll_ms (or a default when 0) to whole seconds, floored to
// a minimum of 1 — the unit the inject `repeat` and modbus `rate` fields expect.
func pollSeconds(pollMS, defaultMS int) int {
	ms := pollMS
	if ms <= 0 {
		ms = defaultMS
	}
	s := ms / 1000
	if s < 1 {
		s = 1
	}
	return s
}

// splitHostPort splits an "host:port" endpoint, defaulting the port when absent.
// A bare host (or an IPv4 with no port) returns (host, defaultPort). It deliberately
// does not handle bracketed IPv6 — factory PLC endpoints are IPv4/host:port.
func splitHostPort(endpoint, defaultPort string) (string, string) {
	e := strings.TrimSpace(endpoint)
	if i := strings.LastIndex(e, ":"); i >= 0 {
		host := e[:i]
		port := e[i+1:]
		if host != "" && port != "" {
			return host, port
		}
	}
	return e, defaultPort
}
