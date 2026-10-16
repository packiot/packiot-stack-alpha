package clientdescriptor

import (
	"encoding/json"
	"fmt"
	"strings"
)

// HelperTagsPath is where the Python reader's best-effort "nodered" target posts
// each batch on the factory box (http://127.0.0.1:1880/packiot/tags).
const HelperTagsPath = "/packiot/tags"

// GenerateHelperFlow builds the flow for a Node-RED HELPER box: the PLCs are
// read by the Python reader, which tees every batch it sends to Packiot to this
// Node-RED (best-effort, so a broken helper never affects the data). The helper
// exposes the SAME spot ids as the generated reader, so customizations,
// the inserter and live apply work unchanged:
//
//   - <p>_spot_tags (tap)       ← every batch: {group, endpoint, scan_ts, tags[]},
//     with the HTTP request objects removed (a customization must not answer
//     the reader's request or read its headers).
//   - <p>_spot_publish (entry)  → extra tags {"<full topic>": number} are POSTed
//     to Packiot's ingest with the box's own INGEST_URL / INGEST_KEY (env). Unlike
//     the reader, these are NOT spooled during an internet outage.
//
// The raw-read and agent-response spots don't exist here (the Python reader
// owns those stages); a customization naming them fails generate.
func (d *Descriptor) GenerateHelperFlow() ([]byte, error) {
	p := strings.ToLower(d.Tenant)
	tabID, custTabID := p+"_reader_tab", p+"_cust_tab"
	in, ok, scrub := p+"_helper_in", p+"_helper_ok", p+"_spot_tags_scrub"
	build, post, res := p+"_helper_build", p+"_helper_post", p+"_helper_result"

	nodes := []map[string]any{
		{"id": tabID, "type": "tab", "label": d.Tenant + " data from the PLC reader", "disabled": false,
			"info": "Generated. The Python PLC reader sends every batch here (best-effort). Put your own logic on the '" +
				d.Tenant + " customizations' tab and connect it to the connection points (spots) on this tab."},
		{"id": custTabID, "type": "tab", "label": d.Tenant + " customizations", "disabled": false,
			"info": "Your flows. Saved in Packiot (Customize → Node-RED flows) and re-applied from there."},
		{"id": in, "type": "http in", "z": tabID, "name": "batches from the PLC reader",
			"url": HelperTagsPath, "method": "post", "upload": false, "swaggerDoc": "",
			"x": 180, "y": 100, "wires": []any{[]any{ok, scrub}}},
		{"id": ok, "type": "http response", "z": tabID, "name": "200 to the reader",
			"statusCode": "200", "headers": map[string]any{}, "x": 440, "y": 60, "wires": []any{}},
		{"id": scrub, "type": "change", "z": tabID, "name": "keep only the batch",
			"rules": []any{
				map[string]any{"t": "delete", "p": "req", "pt": "msg"},
				map[string]any{"t": "delete", "p": "res", "pt": "msg"},
				map[string]any{"t": "delete", "p": "headers", "pt": "msg"},
			},
			"x": 440, "y": 140, "wires": []any{[]any{SpotID(p, "tags")}}},
		{"id": SpotID(p, "tags"), "type": "link out", "z": tabID, "name": "spot: tags",
			"mode": "link", "links": []any{}, "x": 660, "y": 140},
		{"id": SpotID(p, "publish"), "type": "link in", "z": tabID, "name": "spot: publish",
			"links": []any{}, "x": 180, "y": 240, "wires": []any{[]any{build}}},
		{"id": build, "type": "function", "z": tabID, "name": "extra tags → Packiot envelope",
			"func": helperPublishBody(d.Tenant, d.Canonical.Prefix), "outputs": 1,
			"noerr": 0, "initialize": "", "finalize": "", "libs": []any{},
			"x": 440, "y": 240, "wires": []any{[]any{post}}},
		{"id": post, "type": "http request", "z": tabID, "name": "POST → Packiot ingest",
			"method": "POST", "ret": "obj", "paytoqs": "ignore", "url": "", "tls": "",
			"persist": false, "proxy": "", "insecureHTTPParser": false, "authType": "",
			"senderr": false, "headers": []any{}, "x": 680, "y": 240, "wires": []any{[]any{res}}},
		{"id": res, "type": "debug", "z": tabID, "name": "ingest result", "active": true,
			"tosidebar": true, "console": false, "complete": "statusCode", "x": 890, "y": 240, "wires": []any{}},
	}

	nodes, err := d.renderCustomizations(nodes, p, custTabID)
	if err != nil {
		return nil, err
	}
	out, err := json.MarshalIndent(nodes, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal helper flow: %w", err)
	}
	return append(out, '\n'), nil
}

// helperPublishBody turns {"<full canonical topic>": number, …} into the ingest
// envelope, stripping the canonical prefix exactly like the reader does, and
// reads the URL/key/group from the box env (never baked into the flow).
func helperPublishBody(tenant, prefix string) string {
	return "// Generated: extra tags from a customization → Packiot ingest.\n" +
		"const url = env.get(\"INGEST_URL\");\n" +
		"const key = env.get(\"INGEST_KEY\");\n" +
		"if (!url || !key) { node.error(\"INGEST_URL / INGEST_KEY not set on the box\", msg); return null; }\n" +
		"const PREFIX = " + fmt.Sprintf("%q", prefix) + ";\n" +
		"const p = msg.payload;\n" +
		"if (!p || typeof p !== \"object\" || Array.isArray(p)) { node.warn(\"send { \\\"<full topic>\\\": number }\"); return null; }\n" +
		"const ts = Date.now();\n" +
		"const tags = [];\n" +
		"for (const k of Object.keys(p)) {\n" +
		"    const v = p[k];\n" +
		"    if (typeof v !== \"number\" || !isFinite(v)) continue;\n" +
		"    tags.push({ metric: k.indexOf(PREFIX) === 0 ? k.slice(PREFIX.length) : k, value: v, ts: ts });\n" +
		"}\n" +
		"if (!tags.length) return null;\n" +
		"msg.url = url;\n" +
		"msg.headers = { \"Content-Type\": \"application/json\", \"X-Ingest-Key\": key };\n" +
		"msg.payload = { group: env.get(\"GROUP\") || " + fmt.Sprintf("%q", tenant) + ", endpoint: \"nodered-helper\", scan_ts: ts, tags: tags };\n" +
		"return msg;\n"
}
