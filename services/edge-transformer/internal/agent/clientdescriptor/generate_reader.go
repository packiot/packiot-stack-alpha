package clientdescriptor

// generate_reader.go closes the last gap in the ADR-0045 config-as-data onboarding
// story: the AUTONOMOUS (self-contained) edge.
//
// GenerateTeeSnippet (generate.go, artifact 4) emits only a *tee* — a second wire
// off an EXISTING SparkPlug-assembly node the client already runs. That assumes a
// factory whose Node-RED already reads its PLCs. A greenfield client onboarded from
// CS-Admin has no such flow: the descriptor is the ONLY thing authored, so the
// generated bundle must also bring its OWN PLC reader — as a Node-RED flow, which
// doubles as the per-client customization/integration surface.
//
// ONE plc config, two readers
// ---------------------------
// The single source of truth is the descriptor's `plc:` block (Descriptor.PLC, the
// #684 DescriptorPLC schema: endpoints + s7/modbus/opcua tag maps). It already
// drives GenerateClientYAML (the Go s7/modbus/opcua-reader's client.yaml). This
// file adds the SECOND consumer of the SAME block: GeneratePlcReaderFlow, which maps
// those endpoints + tag maps into a Node-RED flow — protocol input nodes
// (node-red-contrib-s7 / -opcua / -modbus) → a shared normalize `function` → an
// `http request` that POSTs the rawtag { endpoint, scan_ts, tags[] } envelope
// (with an X-Ingest-Key auth header) to the LOCAL sparkplug-agent HTTP ingest
// (:9104/v1/tags — rawtag.Decode). Both readers are dumb producers of raw named
// tags (metric = canonical SUFFIX); the agent owns all canonical mapping (ADR-0045
// §2.3 Option B), so every per-tenant quirk still lives stack-side, never in the
// generated flow. A tenant picks ONE reader deployable (Go container OR Node-RED)
// off the one config, and they can never disagree because they read the same block.

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

// defaultAgentURL is the local sparkplug-agent HTTP ingest the reader POSTs to. It
// is a Docker service name (sparkplug-agent) reachable inside the edge bundle's
// compose network — the same fix as the CPACK live-box bug (a localhost URL only
// worked from the host, not from the Node-RED container).
const defaultAgentURL = "http://sparkplug-agent:9104/v1/tags"

// Reader poll defaults (ms) when an endpoint omits polling_interval.
const (
	defaultOpcuaPollMS  = 10000
	defaultModbusPollMS = 15000
	defaultS7PollMS     = 15000
	defaultModbusPort   = "502"
)

// GeneratePlcReaderFlow builds the Node-RED PLC-reader flow (the autonomous-edge
// artifact) from the descriptor's `plc:` block. It is a PURE function of the
// (already-validated) descriptor, and node ids are DETERMINISTIC (derived from
// tenant + protocol + endpoint index) so regenerating the same descriptor yields a
// byte-stable diff — the discipline every ADR-0045 generator holds.
//
// It returns an error when the descriptor carries no plc block (d.PLC == nil): the
// caller (Generate) gates on d.PLC before invoking, exactly like GenerateClientYAML.
//
// Two tabs are emitted:
//   - "<Tenant> PLC reader" — the generated reader (sources → normalize → POST).
//   - "<Tenant> customizations" — a first-class, intentionally EMPTY tab where a CS
//     engineer adds per-client integrations. Node-RED is the customization surface,
//     not just a reader; keeping customizations on their own tab means regenerating
//     the reader tab never clobbers them.
func (d *Descriptor) GeneratePlcReaderFlow() ([]byte, error) {
	if d.PLC == nil {
		return nil, fmt.Errorf("descriptor has no plc block — nothing to generate for the reader flow")
	}

	p := strings.ToLower(d.Tenant) // node-id prefix + default gateway/env stems
	gateway := p + "-edge"
	urlEnv := strings.ToUpper(d.Tenant) + "_AGENT_URL"

	tabID := p + "_reader_tab"
	custTabID := p + "_cust_tab"
	fnID := p + "_reader_norm"
	httpID := p + "_reader_http"
	switchID := p + "_reader_route"
	okID := p + "_reader_ok"
	errID := p + "_reader_err"

	nodes := []map[string]any{
		{
			"id":       tabID,
			"type":     "tab",
			"label":    d.Tenant + " PLC reader",
			"disabled": false,
			"info": "Generated from the ADR-0045 descriptor plc: block — the SAME source of truth " +
				"the Go reader's client.yaml is generated from. Reads the factory PLCs and POSTs raw " +
				"tags (metric = canonical SUFFIX, tenant prefix stripped) in the rawtag { endpoint, scan_ts, " +
				"tags[] } envelope with an X-Ingest-Key header to the local sparkplug-agent (default " +
				defaultAgentURL + ", override with env " + urlEnv + "). Each endpoint's HOST is read from " +
				"a Node-RED env var PLC_HOST_<ENDPOINT> (never a baked secret) — e.g. an endpoint " +
				"\"S7 115\" reads ${PLC_HOST_S7_115}. This flow is a DUMB producer; the agent does the " +
				"canonical mapping. Do not hand-edit — edit the descriptor + regenerate. Put per-client " +
				"integrations on the '" + d.Tenant + " customizations' tab instead.",
		},
		{
			"id":       custTabID,
			"type":     "tab",
			"label":    d.Tenant + " customizations",
			"disabled": false,
			"info": "Per-client customization surface — the reason the edge deployable is Node-RED, not " +
				"just a Go reader. Add integration function nodes, extra http-request calls to edge-api " +
				"(PO control / downtimes), bespoke transforms, dashboards, etc. HERE. This tab is NEVER " +
				"touched by regeneration: onboard-gen only rewrites the '" + d.Tenant + " PLC reader' tab, " +
				"so anything on this tab survives a descriptor edit + regenerate. Start it empty.",
		},
	}

	// yCursor lays flow nodes out top-to-bottom in the source column so a large
	// tenant stays readable. Config nodes (endpoints/clients) carry no x/y — Node-RED
	// keeps them in the config drawer.
	const (
		xSource = 200
		xItem   = 420
		xClient = 640
		yStep   = 80
	)
	yCursor := 100

	for i, ep := range d.PLC.Endpoints {
		hostVar := "${" + hostEnvVar(ep.Name) + "}"

		switch ep.Protocol {
		case PLCProtocolS7:
			epID := fmt.Sprintf("%s_s7_%d_ep", p, i)
			inID := fmt.Sprintf("%s_s7_%d_in", p, i)
			vartable := s7Vartable(d.PLC.S7TagMap, ep.Name)
			nodes = append(nodes, s7EndpointNode(epID, ep, hostVar, vartable))
			nodes = append(nodes, map[string]any{
				"id": inID, "type": "s7 in", "z": tabID,
				"endpoint": epID, "mode": "all", "variable": "", "diff": false,
				"name": "read " + ep.Name,
				"x":    xSource, "y": yCursor, "wires": []any{[]any{fnID}},
			})
			yCursor += yStep

		case PLCProtocolOPCUA:
			epID := fmt.Sprintf("%s_opcua_%d_ep", p, i)
			clientID := fmt.Sprintf("%s_opcua_%d_client", p, i)
			tickID := fmt.Sprintf("%s_opcua_%d_tick", p, i)
			nodes = append(nodes, opcuaEndpointNode(epID, ep, hostVar))
			// One inject tick drives every item of this endpoint; each item feeds the
			// client, which performs the read and emits value → normalize.
			itemIDs := make([]any, 0)
			itemY := yCursor
			j := 0
			for _, m := range d.PLC.OPCUATagMap {
				if m.Endpoint != ep.Name {
					continue
				}
				for _, t := range m.Tags {
					if t.Source != nil { // derived tag — no OPC-UA node to read
						continue
					}
					itemID := fmt.Sprintf("%s_opcua_%d_item_%d", p, i, j)
					j++
					itemIDs = append(itemIDs, itemID)
					nodes = append(nodes, map[string]any{
						"id": itemID, "type": "OpcUa-Item", "z": tabID,
						"item": t.NodeID, "datatype": opcuaDatatype(t.Type), "value": "",
						"name": m.PackMLTopic + t.Metric,
						"x":    xItem, "y": itemY, "wires": []any{[]any{clientID}},
					})
					itemY += yStep
				}
			}
			nodes = append(nodes, map[string]any{
				"id": tickID, "type": "inject", "z": tabID,
				"name":   "poll " + ep.Name,
				"props":  []any{map[string]any{"p": "payload"}},
				"repeat": strconv.Itoa(pollSeconds(pollMS(ep.PollingInterval, defaultOpcuaPollMS))),
				"crontab": "", "once": true, "onceDelay": "1",
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
				"name": "read " + ep.Name,
				"x":    xClient, "y": yCursor, "wires": []any{[]any{fnID}},
			})
			if itemY > yCursor+yStep {
				yCursor = itemY
			} else {
				yCursor += yStep
			}

		case PLCProtocolModbusTCP:
			clientID := fmt.Sprintf("%s_mb_%d_client", p, i)
			unit := 1
			if ep.UnitID != nil {
				unit = *ep.UnitID
			}
			nodes = append(nodes, modbusClientNode(clientID, ep, hostVar, unit))
			// One modbus-read per polled tag: the read's `topic` carries the full
			// canonical topic so the normalize fn can name the register value.
			for _, m := range d.PLC.ModbusTagMap {
				if m.Endpoint != ep.Name {
					continue
				}
				for k, t := range m.Tags {
					if t.Source != nil { // derived tag — no register to read
						continue
					}
					readID := fmt.Sprintf("%s_mb_%d_read_%d", p, i, k)
					qty := t.Quantity
					if qty <= 0 {
						qty = 1
					}
					nodes = append(nodes, map[string]any{
						"id": readID, "type": "modbus-read", "z": tabID,
						"name": "read " + ep.Name, "topic": m.PackMLTopic + t.Metric,
						"showStatusActivities": false, "logIOActivities": false,
						"showErrors": false, "showWarnings": true,
						"unitid": strconv.Itoa(unit), "dataType": modbusDataType(t.Kind),
						"adr": strconv.Itoa(t.Address), "quantity": strconv.Itoa(qty),
						"rate": strconv.Itoa(pollSeconds(pollMS(ep.PollingInterval, defaultModbusPollMS))), "rateUnit": "s",
						"delayOnStart": false, "startDelayTime": "",
						"server": clientID, "useIOFile": false, "ioFile": "",
						"useIOForPayload": false, "emptyMsgOnFail": false,
						"x": xSource, "y": yCursor, "wires": []any{[]any{fnID}, []any{}},
					})
					yCursor += yStep
				}
			}
		}
	}

	// Shared normalize function + POST chain, to the right of the sources.
	midY := 100 + (len(nodes)*yStep)/6
	nodes = append(nodes,
		map[string]any{
			"id": fnID, "type": "function", "z": tabID,
			"name":    d.Tenant + " normalize → raw tags",
			"func":    readerFunctionBody(d.Tenant, gateway, urlEnv, "AGENT_INGEST_API_KEY", d.Canonical.Prefix),
			"outputs": 1, "noerr": 0, "initialize": "", "finalize": "", "libs": []any{},
			"x": 900, "y": midY, "wires": []any{[]any{httpID}},
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
			"x":       1120, "y": midY, "wires": []any{[]any{switchID}},
		},
		map[string]any{
			"id": switchID, "type": "switch", "z": tabID,
			"name": "statusCode", "property": "statusCode", "propertyType": "msg",
			"rules": []any{
				map[string]any{"t": "lt", "v": "300", "vt": "num"},
				map[string]any{"t": "else"},
			},
			"checkall": "false", "repair": false, "outputs": 2,
			"x": 1320, "y": midY, "wires": []any{[]any{okID}, []any{errID}},
		},
		map[string]any{
			"id": okID, "type": "debug", "z": tabID, "name": "2xx accepted",
			"active": true, "tosidebar": true, "console": false, "complete": "statusCode",
			"x": 1520, "y": midY - 40, "wires": []any{},
		},
		map[string]any{
			"id": errID, "type": "debug", "z": tabID, "name": "ingest error",
			"active": true, "tosidebar": true, "console": true, "complete": "payload",
			"x": 1520, "y": midY + 40, "wires": []any{},
		},
	)

	out, err := json.MarshalIndent(nodes, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal plc reader flow: %w", err)
	}
	return append(out, '\n'), nil
}

// s7Vartable builds the node-red-contrib-s7 endpoint `vartable` for one endpoint by
// aggregating every s7 tag map that references it (the multisource "two maps, one
// PLC" shape). Each vartable entry's Node-RED variable NAME is the FULL canonical
// topic (packml_topic + metric — the exact string the agent resolves), and its addr
// is built from {db, offset, type} → "DB<db>,<TYPE><offset>". Derived tags
// (Source != nil) have no physical S7 address and are skipped.
func s7Vartable(maps []clientconfig.S7EndpointTags, endpoint string) []any {
	var vartable []any
	for _, m := range maps {
		if m.Endpoint != endpoint {
			continue
		}
		for _, t := range m.Tags {
			if t.Source != nil {
				continue
			}
			vartable = append(vartable, map[string]any{
				"addr": s7Address(t.DB, t.Offset, t.Bit, t.Type),
				"name": m.PackMLTopic + t.Metric,
				"type": strings.ToUpper(t.Type),
			})
		}
	}
	return vartable
}

// s7EndpointNode builds a node-red-contrib-s7 `s7 endpoint` config node. Field names
// + defaults are copied verbatim from the real CPACK flow so the palette recognises
// them. address is a ${PLC_HOST_<ENDPOINT>} env reference (Node-RED substitutes it at
// deploy time) — never the secret host_ref value. cycletime carries the endpoint's
// polling_interval; the vartable is the caller-built canonical-name table.
func s7EndpointNode(id string, ep DescriptorPLCEndpoint, hostVar string, vartable []any) map[string]any {
	if vartable == nil {
		vartable = []any{}
	}
	return map[string]any{
		"id": id, "type": "s7 endpoint",
		"transport": "iso-on-tcp", "address": hostVar, "port": "102",
		"rack": strconv.Itoa(intOr(ep.Rack, 0)), "slot": strconv.Itoa(intOr(ep.Slot, 0)),
		"localtsaphi": "01", "localtsaplo": "00",
		"remotetsaphi": "02", "remotetsaplo": "00",
		"connmode": "rack-slot", "adapter": "", "busaddr": strconv.Itoa(intOr(ep.Slot, 0)),
		"cycletime": strconv.Itoa(pollMS(ep.PollingInterval, defaultS7PollMS)), "timeout": "1500",
		"name":     ep.Name,
		"vartable": vartable,
	}
}

// opcuaEndpointNode builds a node-red-contrib-opcua `OpcUa-Endpoint` config node.
// endpoint is a ${PLC_HOST_<ENDPOINT>} env reference (the OPC-UA URL is a secret,
// endpoint_url_ref, so it is injected at runtime, never baked). secpol/secmode
// default to the endpoint's declared policy/mode or "None" (the MVP default).
func opcuaEndpointNode(id string, ep DescriptorPLCEndpoint, hostVar string) map[string]any {
	secpol := ep.SecurityPolicy
	if secpol == "" {
		secpol = "None"
	}
	secmode := ep.SecurityMode
	if secmode == "" {
		secmode = "None"
	}
	return map[string]any{
		"id": id, "type": "OpcUa-Endpoint",
		"endpoint": hostVar, "secpol": secpol, "secmode": secmode,
		"none": secpol == "None", "login": false, "usercert": false,
		"usercertificate": "", "userprivatekey": "",
	}
}

// modbusClientNode builds a node-red-contrib-modbus `modbus-client` config node
// (TCP). tcpHost is a ${PLC_HOST_<ENDPOINT>} env reference; the port defaults to 502
// (the descriptor's host_ref carries only the host). Serial fields carry the
// palette's harmless defaults so the node validates even though clienttype=tcp.
func modbusClientNode(id string, ep DescriptorPLCEndpoint, hostVar string, unit int) map[string]any {
	return map[string]any{
		"id": id, "type": "modbus-client",
		"name": ep.Name, "clienttype": "tcp",
		"bufferCommands": true, "stateLogEnabled": false, "queueLogEnabled": false,
		"tcpHost": hostVar, "tcpPort": defaultModbusPort, "tcpType": "DEFAULT",
		"serialPort": "/dev/ttyUSB", "serialType": "RTU-BUFFERD",
		"serialBaudrate": "9600", "serialDatabits": "8", "serialStopbits": "1",
		"serialParity": "none", "serialConnectionDelay": "100",
		"unit_id": unit, "commandDelay": 1, "clientTimeout": 1000,
		"reconnectOnTimeout": true, "reconnectTimeout": 30000,
		"parallelUnitIdsAllowed": false,
	}
}

// readerFunctionBody renders the shared normalize `function` node body. It reads the
// per-endpoint payload shape, folds each reading into a { metric, value, ts } tag
// keyed by the canonical SUFFIX (full canonical topic with the tenant prefix stripped,
// matching how the agent's raw_tag_map is keyed — ADR-0045 §2.4), and emits the
// rawtag envelope { endpoint, scan_ts, tags[] } that the agent's /v1/tags endpoint
// (rawtag.Decode) expects. The ingest key is read from env (never hardcoded).
//
// Payload shapes (see the source nodes):
//   - S7 "all" mode → msg.payload is an OBJECT { canonicalTopic: value, … }.
//   - Modbus read → register ARRAY with msg.topic = the canonical topic.
//   - OPC-UA read → scalar; identity on msg.topic / msg.name.
func readerFunctionBody(tenant, gateway, urlEnv, keyEnv, prefix string) string {
	return "// " + tenant + " PLC reader → sparkplug-agent — generated from the descriptor plc: block.\n" +
		"// DUMB producer: emits raw tags (metric = canonical suffix); the agent maps them.\n" +
		"// Override the agent ingest URL with env " + urlEnv + " (default " + defaultAgentURL + ").\n" +
		"// The ingest key is read from env " + keyEnv + " — NEVER hardcoded.\n" +
		"\n" +
		"const url = env.get(\"" + urlEnv + "\") || \"" + defaultAgentURL + "\";\n" +
		"const key = env.get(\"" + keyEnv + "\");\n" +
		"if (!key) {\n" +
		"    node.error(\"" + keyEnv + " env var is not set — refusing to POST without an ingest key\", msg);\n" +
		"    return null;\n" +
		"}\n" +
		"// The agent's raw_tag_map is keyed by the canonical SUFFIX (topic minus the\n" +
		"// tenant prefix). Source-node names carry the FULL canonical topic, so strip\n" +
		"// the prefix here to match the map — otherwise every tag is dropped unmapped.\n" +
		"const PREFIX = \"" + prefix + "\";\n" +
		"function suffix(n) { return (n && n.indexOf(PREFIX) === 0) ? n.slice(PREFIX.length) : n; }\n" +
		"const ts = Date.now();\n" +
		"const tags = [];\n" +
		"const p = msg.payload;\n" +
		"if (p && typeof p === \"object\" && !Array.isArray(p)) {\n" +
		"    // S7 \"all\" mode: { canonicalTopic: value, … } — one tag per numeric entry.\n" +
		"    for (const k of Object.keys(p)) {\n" +
		"        const v = p[k];\n" +
		"        if (typeof v === \"number\" && isFinite(v)) tags.push({ metric: suffix(k), value: v, ts: ts });\n" +
		"    }\n" +
		"} else if (Array.isArray(p) && msg.topic) {\n" +
		"    // Modbus read: register array + canonical topic on msg.topic → first register.\n" +
		"    const v = Number(p[0]);\n" +
		"    if (isFinite(v)) tags.push({ metric: suffix(msg.topic), value: v, ts: ts });\n" +
		"} else if (typeof p === \"number\" && isFinite(p)) {\n" +
		"    // OPC-UA (or any scalar) read: identity on msg.topic / msg.name.\n" +
		"    const name = msg.topic || msg.name;\n" +
		"    if (name) tags.push({ metric: suffix(name), value: p, ts: ts });\n" +
		"}\n" +
		"\n" +
		"if (tags.length === 0) {\n" +
		"    node.warn(\"reader: no numeric tags in this message; skipping\");\n" +
		"    return null;\n" +
		"}\n" +
		"\n" +
		"msg.url = url;\n" +
		"msg.headers = { \"Content-Type\": \"application/json\", \"X-Ingest-Key\": key };\n" +
		"msg.payload = { endpoint: \"" + gateway + "\", scan_ts: ts, tags: tags };\n" +
		"return msg;\n"
}

// s7Address builds a node-red-contrib-s7 address from a tag's {db, offset, bit, type}.
// The type token is uppercased (int→INT, dint→DINT, real→REAL); a bool becomes the
// bit form "DB<db>,X<offset>.<bit>". This is the inverse of the S7 addressing the Go
// s7-reader parses, so the same physical tag is addressed identically both ways.
func s7Address(db, offset, bit int, typ string) string {
	t := strings.ToUpper(strings.TrimSpace(typ))
	if t == "BOOL" || t == "X" {
		return fmt.Sprintf("DB%d,X%d.%d", db, offset, bit)
	}
	return fmt.Sprintf("DB%d,%s%d", db, t, offset)
}

// opcuaDatatype maps a descriptor OPC-UA tag type (int|float|bool|string) to the
// node-red-contrib-opcua OpcUa-Item datatype token. Counters read as Double.
func opcuaDatatype(typ string) string {
	switch strings.ToLower(strings.TrimSpace(typ)) {
	case "bool":
		return "Boolean"
	case "string":
		return "String"
	case "int":
		return "Int32"
	default:
		return "Double"
	}
}

// modbusDataType maps a descriptor Modbus tag kind (holding|input|coil|discrete) to
// the node-red-contrib-modbus modbus-read dataType token.
func modbusDataType(kind string) string {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "input":
		return "InputRegister"
	case "coil":
		return "Coil"
	case "discrete":
		return "DiscreteInput"
	default:
		return "HoldingRegister"
	}
}

// hostEnvVar derives the Node-RED env var an endpoint's host is read from:
// PLC_HOST_<SANITIZED_NAME>, where the name is uppercased and every run of
// non-alphanumeric characters collapses to a single underscore (so "S7 115" →
// PLC_HOST_S7_115, "PLC L4 10.135.1.126" → PLC_HOST_PLC_L4_10_135_1_126). This
// matches the per-endpoint reader host convention and keeps the flow secret-free.
func hostEnvVar(name string) string {
	var b strings.Builder
	prevUnderscore := false
	for _, r := range strings.ToUpper(strings.TrimSpace(name)) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			prevUnderscore = false
			continue
		}
		if !prevUnderscore {
			b.WriteByte('_')
			prevUnderscore = true
		}
	}
	return "PLC_HOST_" + strings.Trim(b.String(), "_")
}

// pollMS resolves an endpoint's polling_interval (a Go duration string like "1s" /
// "30s") to milliseconds, falling back to the protocol default when empty or
// unparseable — a bad duration should degrade to a sane poll, not fail generation.
func pollMS(pollingInterval string, defaultMS int) int {
	if s := strings.TrimSpace(pollingInterval); s != "" {
		if dur, err := time.ParseDuration(s); err == nil && dur > 0 {
			return int(dur.Milliseconds())
		}
	}
	return defaultMS
}

// pollSeconds converts milliseconds to whole seconds, floored to 1 — the unit the
// inject `repeat` and modbus `rate` fields expect.
func pollSeconds(ms int) int {
	s := ms / 1000
	if s < 1 {
		s = 1
	}
	return s
}

// intOr dereferences an optional int (endpoint rack/slot), returning def when nil.
func intOr(p *int, def int) int {
	if p != nil {
		return *p
	}
	return def
}
