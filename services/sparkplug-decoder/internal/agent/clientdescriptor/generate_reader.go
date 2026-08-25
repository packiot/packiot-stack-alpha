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
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
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

// ReaderFlowOptions parameterizes the generated reader flow. The zero value is the
// historical behaviour (no staging tee), so every existing caller — and every
// descriptor that predates this option — regenerates byte-identically.
type ReaderFlowOptions struct {
	// StagingTee adds a SECOND, parallel POST branch off the normalize function so
	// the SAME reader can dual-publish: its primary POST to the local sparkplug-agent
	// (the prod/edge path) AND an optional POST to a staging ingest front door (e.g.
	// cpack-ingest.staging:8447/v2/tags). It is OFF by default; even when compiled in,
	// the staging branch is INERT at runtime until BOTH its env vars are set
	// (<TENANT>_STAGING_TEE_URL + <TENANT>_STAGING_TEE_KEY) — the staging URL and the
	// CLOUD agent ingest key are read from env, never baked (same secret-free posture
	// as the primary branch). This is the mechanism the twin re-point uses to fan a
	// live factory reader onto the staging analytics plane without a second reader.
	StagingTee bool
}

// GeneratePlcReaderFlow builds the Node-RED PLC-reader flow (the autonomous-edge
// artifact) from the descriptor's `plc:` block. It is a PURE function of the
// (already-validated) descriptor, and node ids are DETERMINISTIC (derived from
// tenant + protocol + endpoint index) so regenerating the same descriptor yields a
// byte-stable diff — the discipline every ADR-0045 generator holds.
//
// It returns an error when the descriptor carries no plc block (d.PLC == nil): the
// caller (Generate) gates on d.PLC before invoking, exactly like GenerateClientYAML.
//
// opts is variadic so the historical no-arg call site keeps working; only the first
// element is read (a nil/empty opts ⇒ the zero ReaderFlowOptions ⇒ historical output).
//
// Two tabs are emitted:
//   - "<Tenant> PLC reader" — the generated reader (sources → normalize → POST).
//   - "<Tenant> customizations" — a first-class, intentionally EMPTY tab where a CS
//     engineer adds per-client integrations. Node-RED is the customization surface,
//     not just a reader; keeping customizations on their own tab means regenerating
//     the reader tab never clobbers them.
func (d *Descriptor) GeneratePlcReaderFlow(opts ...ReaderFlowOptions) ([]byte, error) {
	if d.PLC == nil {
		return nil, fmt.Errorf("descriptor has no plc block — nothing to generate for the reader flow")
	}
	var opt ReaderFlowOptions
	if len(opts) > 0 {
		opt = opts[0]
	}

	p := strings.ToLower(d.Tenant) // node-id prefix + default gateway/env stems
	gateway := p + "-edge"
	urlEnv := strings.ToUpper(d.Tenant) + "_AGENT_URL"
	stagingURLEnv := strings.ToUpper(d.Tenant) + "_STAGING_TEE_URL"
	stagingKeyEnv := strings.ToUpper(d.Tenant) + "_STAGING_TEE_KEY"

	tabID := p + "_reader_tab"
	custTabID := p + "_cust_tab"
	fnID := p + "_reader_norm"
	httpID := p + "_reader_http"
	switchID := p + "_reader_route"
	okID := p + "_reader_ok"
	errID := p + "_reader_err"
	stagingHTTPID := p + "_reader_staging_http"
	stagingOkID := p + "_reader_staging_ok"

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
				"just a Go reader. Integration function nodes, extra http-request calls to edge-api " +
				"(PO control / downtimes), bespoke transforms, dashboards, etc. live HERE. This tab is " +
				"DESCRIPTOR-SOURCED (ADR-0045 §G3): its nodes come from the descriptor's `customizations` " +
				"block (authored in CS-Admin), so they are versioned and re-emitted on every regeneration " +
				"— NOT hand-added on the box (which the nodered-data volume would lose on redeploy). To add " +
				"an integration: build + Export it in Node-RED, paste the exported nodes into the CS-Admin " +
				"customizations editor, and regenerate. Empty when the descriptor declares no customizations.",
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
				"name":    "poll " + ep.Name,
				"props":   []any{map[string]any{"p": "payload"}},
				"repeat":  strconv.Itoa(pollSeconds(pollMS(ep.PollingInterval, defaultOpcuaPollMS))),
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
			//
			// readIdx is a per-ENDPOINT running counter, NOT the per-map tag index.
			// A single Modbus endpoint (e.g. CPACK's PLC_L6) is referenced by MANY
			// modbus_tag_map entries — one per member (BREYER, POLYTYPE, PTH, RMH,
			// TEXA), each with its own PackMLTopic + 1–2 Tags. Keying the node id off
			// the inner `range m.Tags` index restarted at 0 for every member, so the
			// 8 L6 reads collapsed onto just two ids (`_read_0` ×5, `_read_1` ×3).
			// Node-RED requires globally-unique node ids and keeps only the LAST
			// definition per id, so 6 of the 8 reads were silently dropped and only
			// the two survivors (both resolving to adr 0 = TEXA) ever polled — the
			// root cause of the twin re-point P0 block (only L6/TEXA reached Calc,
			// BREYER/POLYTYPE/RMH/PTH went dark). Counting across ALL of this
			// endpoint's maps makes every read id unique (`_read_{0..N}`).
			readIdx := 0
			for _, m := range d.PLC.ModbusTagMap {
				if m.Endpoint != ep.Name {
					continue
				}
				for _, t := range m.Tags {
					if t.Source != nil { // derived tag — no register to read
						continue
					}
					readID := fmt.Sprintf("%s_mb_%d_read_%d", p, i, readIdx)
					readIdx++
					qty := t.Quantity
					if qty <= 0 {
						// Derive from type (field doc: "0 = derive from type"). A 32-bit
						// totalizer read as a single 16-bit register yields the low word
						// only → wrong/wrapping counts. Mirrors the Go reader's width.
						qty = modbusRegisterSpan(t.Type)
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

	// 32-bit Modbus tags whose two-register value is low-word-first (word_swap) —
	// the normalize fn must recombine them (reg[1]*65536 + reg[0]); a plain p[0]
	// would drop the high word. Keyed by full canonical topic (the read node's topic).
	mbWS := map[string]bool{}
	if d.PLC != nil {
		for _, m := range d.PLC.ModbusTagMap {
			for _, t := range m.Tags {
				if t.WordSwap && modbusRegisterSpan(t.Type) >= 2 {
					mbWS[m.PackMLTopic+t.Metric] = true
				}
			}
		}
	}

	// Shared normalize function + POST chain, to the right of the sources.
	midY := 100 + (len(nodes)*yStep)/6
	// The normalize function has ONE output normally; with the staging tee it has a
	// SECOND output carrying a clone of the rawtag POST addressed to the staging
	// front door — wired to its own http-request node. When the tee is off the flow
	// is byte-identical to the historical output.
	fnOutputs := 1
	fnWires := []any{[]any{httpID}}
	if opt.StagingTee {
		fnOutputs = 2
		fnWires = []any{[]any{httpID}, []any{stagingHTTPID}}
	}
	nodes = append(nodes,
		map[string]any{
			"id": fnID, "type": "function", "z": tabID,
			"name":    d.Tenant + " normalize → raw tags",
			"func":    readerFunctionBody(d.Tenant, gateway, urlEnv, "AGENT_INGEST_API_KEY", d.Canonical.Prefix, mbWS, opt.StagingTee, stagingURLEnv, stagingKeyEnv),
			"outputs": fnOutputs, "noerr": 0, "initialize": "", "finalize": "", "libs": []any{},
			"x": 900, "y": midY, "wires": fnWires,
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

	// Optional staging tee: a SECOND http-request node fed by the normalize
	// function's 2nd output. It mirrors the primary POST config (url empty ⇒ the
	// function's msg.url from env wins) so it stays secret-free; it fires only when
	// the function actually emitted a staging message (both staging env vars set).
	if opt.StagingTee {
		nodes = append(nodes,
			map[string]any{
				"id": stagingHTTPID, "type": "http request", "z": tabID,
				"name":   "POST → staging tee (:8447/v2/tags)",
				"method": "POST", "ret": "obj", "paytoqs": "ignore",
				"url": "", "tls": "", "persist": false, "proxy": "",
				"insecureHTTPParser": false, "authType": "", "senderr": true,
				"headers": []any{},
				"x":       1120, "y": midY + 120, "wires": []any{[]any{stagingOkID}},
			},
			map[string]any{
				"id": stagingOkID, "type": "debug", "z": tabID, "name": "staging tee result",
				"active": true, "tosidebar": true, "console": false, "complete": "statusCode",
				"x": 1360, "y": midY + 120, "wires": []any{},
			},
		)
	}

	// Render the per-client customizations onto the customizations tab. Each entry
	// is a raw Node-RED node (a CS engineer's "Export" from Node-RED). This is what
	// makes the customization surface DESCRIPTOR-SOURCED + versioned (ADR-0045 G3):
	// the tab is no longer emitted empty with integrations hand-added on the box
	// (invisible to CS-Admin, clobbered on redeploy) — they ride the descriptor and
	// re-emit on every regeneration.
	//
	//   - A FLOW node (one carrying a "z" tab reference) is re-homed onto the
	//     customizations tab so it lands there regardless of which tab it was
	//     exported from; a CONFIG node (no "z", tab-less) passes through untouched.
	//   - A customization id colliding with a GENERATED reader node id is a
	//     fail-closed error: Node-RED silently breaks a flow with duplicate ids.
	reserved := make(map[string]bool, len(nodes))
	for _, n := range nodes {
		if id, ok := n["id"].(string); ok {
			reserved[id] = true
		}
	}
	for i, cn := range d.Customizations {
		// Shallow-copy so re-homing "z" never mutates the descriptor's own map.
		node := make(map[string]any, len(cn))
		for k, v := range cn {
			node[k] = v
		}
		id, _ := node["id"].(string)
		if reserved[id] {
			return nil, fmt.Errorf("customizations[%d]: node id %q collides with a generated reader node id "+
				"— rename it (the '%s PLC reader' tab owns that id)", i, id, d.Tenant)
		}
		reserved[id] = true
		if _, isFlowNode := node["z"]; isFlowNode {
			node["z"] = custTabID
		}
		nodes = append(nodes, node)
	}

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
func readerFunctionBody(tenant, gateway, urlEnv, keyEnv, prefix string, mbWS map[string]bool, stagingTee bool, stagingURLEnv, stagingKeyEnv string) string {
	// Deterministic JS object {full topic → 1} for low-word-first 32-bit Modbus tags.
	wsKeys := make([]string, 0, len(mbWS))
	for t, ws := range mbWS {
		if ws {
			wsKeys = append(wsKeys, t)
		}
	}
	sort.Strings(wsKeys)
	mbWSDecl := "const MB_WS = {"
	for _, t := range wsKeys {
		mbWSDecl += fmt.Sprintf("%q:1,", t)
	}
	mbWSDecl += "};\n"

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
		mbWSDecl +
		"const p = msg.payload;\n" +
		"if (p && typeof p === \"object\" && !Array.isArray(p)) {\n" +
		"    // S7 \"all\" mode: { canonicalTopic: value, … } — one tag per numeric entry.\n" +
		"    for (const k of Object.keys(p)) {\n" +
		"        const v = p[k];\n" +
		"        if (typeof v === \"number\" && isFinite(v)) tags.push({ metric: suffix(k), value: v, ts: ts });\n" +
		"    }\n" +
		"} else if (Array.isArray(p) && msg.topic) {\n" +
		"    // Modbus read: 1 register = 16-bit; 2 registers = 32-bit totalizer.\n" +
		"    // word_swap (MB_WS) ⇒ low word first (CDAB); else high word first (ABCD).\n" +
		"    // Use *65536 (not <<16) to stay in float and avoid 32-bit sign overflow.\n" +
		"    let v;\n" +
		"    if (p.length >= 2) { v = MB_WS[msg.topic] ? (p[1]*65536 + p[0]) : (p[0]*65536 + p[1]); }\n" +
		"    else { v = Number(p[0]); }\n" +
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
		stagingTeeTail(stagingTee, stagingURLEnv, stagingKeyEnv)
}

// stagingTeeTail renders the normalize function's return statement. Without the
// staging tee it is a plain `return msg;` (output 1 only) — byte-identical to the
// historical body. With the tee it reads the OPTIONAL staging URL + CLOUD ingest key
// from env and, only when BOTH are present, clones the rawtag POST onto a second
// output addressed to the staging front door — so the branch is compiled in but
// INERT until the env is set (parameterized, off by default). The staging key rides
// its own X-Ingest-Key header; nothing is baked into the flow.
func stagingTeeTail(stagingTee bool, stagingURLEnv, stagingKeyEnv string) string {
	if !stagingTee {
		return "return msg;\n"
	}
	return "\n" +
		"// Optional staging tee (parameterized, OFF unless both env vars are set):\n" +
		"// dual-publish the SAME rawtag envelope to a staging ingest front door on a\n" +
		"// 2nd output. " + stagingURLEnv + " = e.g. https://cpack-ingest.staging.packiot.app:8447/v2/tags,\n" +
		"// " + stagingKeyEnv + " = the CLOUD agent ingest key (distinct from the factory key).\n" +
		"const sUrl = env.get(\"" + stagingURLEnv + "\");\n" +
		"const sKey = env.get(\"" + stagingKeyEnv + "\");\n" +
		"let stagingMsg = null;\n" +
		"if (sUrl && sKey) {\n" +
		"    stagingMsg = {\n" +
		"        url: sUrl,\n" +
		"        headers: { \"Content-Type\": \"application/json\", \"X-Ingest-Key\": sKey },\n" +
		"        payload: msg.payload,\n" +
		"    };\n" +
		"}\n" +
		"return [msg, stagingMsg];\n"
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
// modbusRegisterSpan returns how many 16-bit registers a Modbus value type spans:
// 32-bit types (uint32/int32/float32) need 2, everything else 1. Keeps the Node-RED
// reader's read-width in lockstep with the Go reader (clientconfig type derivation).
func modbusRegisterSpan(typ string) int {
	switch strings.ToLower(strings.TrimSpace(typ)) {
	case "uint32", "int32", "float32":
		return 2
	default:
		return 1
	}
}

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
