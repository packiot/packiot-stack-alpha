// openapi.go — the OpenAPI 3.1 description of this service, served at
// GET /openapi.json.
//
// GENERATED FROM THE SAME TABLES THAT MOUNT THE ROUTES
// ────────────────────────────────────────────────────
// read-api is table-driven: the Generation-A operator reads come from
// `endpoints` (main.go), the foreign-contract shims from `externalShims`
// (external.go), the named datasets from `datasets` (datasets.go) and the
// composer vocabulary from metrics/dimensions/grains (query.go). The spec walks
// those tables (once, on the first request), so a new endpoint/shim/dataset shows up in the spec
// without anyone remembering to edit it. What a table cannot say — a one-line
// summary, a foreign shim's query params and envelope — is hand-written below,
// keyed by path, and the drift gate (openapi_test.go) fails CI when a table row
// has no hand-written entry or a hand-written entry has no table row.
//
// The few hand-registered routes (/v1/catalog, /v1/query, /v1/screen-config,
// /v1/dashboard-config, /v1/historian/*, /internal/resolve-device) get
// hand-written operations; the same gate proves each one is actually mounted.
//
// HONEST SHAPES: most reads stream whatever columns the backing SQL object
// returns, so their 200 body is described as "array of row objects" rather
// than an invented column list. Errors from http.Error are text/plain bodies
// that happen to contain JSON ({"error":"..."}); the shims reproduce back4's
// text/html strings byte-for-byte. The spec says exactly that.
//
// stdlib only: the document is plain maps marshalled once (encoding/json sorts
// map keys, so the bytes are deterministic across restarts).
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"sync"
)

// Security scheme names (components.securitySchemes). Each maps to one REAL
// credential path in code — see the scheme descriptions for the file.
const (
	secAPIKey      = "ApiKey"               // auth.go: X-Api-Key → QUERY_API_KEYS → customer_id
	secBearer      = "CognitoBearer"        // auth_cognito.go + auth_firebase.go: Cognito ID token → users → tenant
	secExtHeader   = "ExternalApiKeyHeader" // external.go headerAPIKeyAuth: x-api-key, owner-bound
	secExtQuery    = "ExternalApiKeyQuery"  // external.go queryAPIKeyAuth / external_integration.go: ?api_key=, owner-bound
	secInternalKey = "InternalKey"          // internal.go: X-Internal-Key ↔ INTERNAL_API_KEY
)

// openAPIServers are the public hostnames that route to this container
// (terraform/{staging,production}/user_data/nginx_setup.sh, the refdata vhost →
// 172.18.0.26:9104) plus local dev (dev/compose.yml read-api-cors on
// 127.0.0.1:${DEV_READAPI_PORT:-9104}, or `go run` with the HEALTH_PORT default).
var openAPIServers = []any{
	map[string]any{"url": "https://refdata.staging.packiot.app", "description": "Staging"},
	map[string]any{"url": "https://refdata.prod.packiot.app", "description": "Production (CloudFront → origin-verify)"},
	map[string]any{"url": "http://localhost:9104", "description": "Local dev"},
}

// ── Example values (placeholders only: no real tenant, key, token or person) ──

const (
	exTopic     = "ACME/Plant1/Packaging/Line1"
	exTopics    = "ACME/Plant1/Packaging/Line1,ACME/Plant1/Packaging/Line1/Filler"
	exEquipment = "101,102"
	exPath      = "ACME / Plant 1 / Packaging / Line 1"
	exDeviceKey = "dk_3f9c2a7e5b1d48c6a0e4f7b2c9d1e8a5"
)

// ── Hand-written enrichment, keyed by path ───────────────────────────────────

// endpointDoc is what an `endpoints` row cannot say. The gate requires one per row.
type endpointDoc struct {
	summary     string // ≤ 10 words (the completeness gate enforces it)
	description string // what the rows are; the tenant/transport notes are appended
	example     any    // 200 body: abridged rows from the backing object
	// supersededBy marks a topic-keyed v1 read whose id-keyed /v2 twin exists
	// (ADR-0061 P3): the operation is flagged deprecated and points at it.
	supersededBy string
}

func withoutKey(row map[string]any, drop string) map[string]any {
	out := make(map[string]any, len(row))
	for k, v := range row {
		if k != drop {
			out[k] = v
		}
	}
	return out
}

var (
	exEventRowV2 = map[string]any{
		"id_equipment_event": 884213, "ts_event": "2026-10-13T08:12:05Z", "ts_end": "2026-10-13T08:19:40Z",
		"duration": 455, "id_equipment": 101, "id_enterprise": 42, "txt_downtime_notes": "Film roll change",
		"cd_machine": "FILLER-01", "cd_category": "MECH", "cd_subcategory": "JAM", "change_over": false,
		"desc_category": "Mechanical", "desc_subcategory": "Jam at infeed", "display_path": exPath,
		"event_type": "downtime", "id_order_text": "PO-2026-0815", "id_production_order": 55120,
		"production_programmed": 12000, "custom_field": nil,
	}
	exPendingRowV2 = map[string]any{
		"id_equipment_event": 884213, "ts_event": "2026-10-13T08:12:05Z", "ts_end": "2026-10-13T08:19:40Z",
		"duration": 455, "id_equipment": 101, "id_enterprise": 42, "display_path": exPath,
	}
	exReasonTree = []any{map[string]any{"id": 1, "name": "Mechanical", "children": []any{
		map[string]any{"id": 11, "name": "Jam at infeed"}, map[string]any{"id": 12, "name": "Belt failure"}}}}
	exScrapTree    = []any{map[string]any{"id": 1, "name": "Seal defect"}}
	exReasonsRowV2 = map[string]any{"id_equipment": 101, "id_enterprise": 42, "downtime_reasons": exReasonTree,
		"scrap_reasons": exScrapTree, "display_path": exPath}
	exPOListRowV2 = map[string]any{
		"id_production_order": 55120, "id_order": 815, "id_order_text": "PO-2026-0815", "id_enterprise": 42,
		"id_equipment": 101, "status": 1, "production_programmed": 12000, "ts_start": nil,
		"equipment_setup": map[string]any{"ideal_speed": 120}, "conversion_factor": 1.0, "custom_field": nil,
		"priority": nil, "display_path": exPath, "nm_client": "ACME Retail", "nm_product_family": "Bottles",
		"nm_product": "Water 500 ml", "txt_product": "WATER-500",
	}
	exNamed = func(id int, name string) map[string]any { return map[string]any{"id": id, "name": name} }
)

// endpointDocs: one entry per `endpoints` row (main.go).
var endpointDocs = map[string]endpointDoc{
	"/v1/events-timeline": {
		summary:      "Event timeline for the given equipment topics",
		description:  "Recent machine events (downtimes, setups, production-order changes) for the equipment named by `topics`, from `serving.events_timeline`. Each row also carries the equipment's legacy SparkPlug topic string.",
		example:      []any{withoutKey(exEventRowV2, "display_path")},
		supersededBy: "/v2/events-timeline",
	},
	"/v1/pending-downtime": {
		summary:      "Downtimes still waiting for a reason (by topic)",
		description:  "Downtime events that the operator has not classified yet, from `serving.pending_downtime`. Each row also carries the equipment's legacy SparkPlug topic string.",
		example:      []any{withoutKey(exPendingRowV2, "display_path")},
		supersededBy: "/v2/pending-downtime",
	},
	"/v1/shift-hours": {
		summary:     "Shift calendar for one equipment topic",
		description: "The shift calendar (one `shift_hours` array per equipment) that applies to the equipment named by `topic`. `begin_time`/`end_time` inside each element are seconds from the week begin, not clock times. Each row also carries the equipment's legacy topic string.",
		example: []any{map[string]any{"id_enterprise": 42, "shift_hours": []any{
			map[string]any{"cd_shift": "T1", "weekday": 1, "begin_time": 21600, "end_time": 50400}}}},
	},
	"/v1/shift-hours-by-enterprise": {
		summary:     "Shift calendar for one topic (enterprise variant)",
		description: "Same rows as GET /v1/shift-hours. The historical `?enterprise=` parameter is gone (ADR-0027): the enterprise is always the caller's tenant; the path is kept because the operator app caches it by URL.",
		example: []any{map[string]any{"id_enterprise": 42, "shift_hours": []any{
			map[string]any{"cd_shift": "T1", "weekday": 1, "begin_time": 21600, "end_time": 50400}}}},
	},
	"/v1/day-week-begin": {
		summary:     "Day and week begin offsets for one topic",
		description: "The site's day-begin and week-begin offsets (seconds; week_begin is relative to Monday 00:00 and may be negative) for the equipment named by `topic`. Each row also carries the equipment's legacy topic string.",
		example:     []any{map[string]any{"id_enterprise": 42, "day_begin": 21600, "week_begin": -3000}},
	},
	"/v1/operator-po-list": {
		summary:      "Operator production-order list (whole tenant)",
		description:  "Every production order the operator app can set up or select, for the whole tenant (`v_operator_po_list_setup_4`). Filter client-side, or use GET /v2/operator-po-list to narrow by equipment.",
		example:      []any{withoutKey(exPOListRowV2, "display_path")},
		supersededBy: "/v2/operator-po-list",
	},
	"/v2/operator-po-list": {
		summary:     "Operator production-order list by equipment id",
		description: "Production orders for the selected lines/sectors and their parent, keyed by id_equipment (ADR-0061 P3, `serving.operator_po_list_by_equipment`). `display_path` is a human label for display only, never an identifier.",
		example:     []any{exPOListRowV2},
	},
	"/v1/operator-po-details": {
		summary:     "Operator production-order details (whole tenant)",
		description: "Per-order runtime detail for the operator app: net production, scrap, running time, downtime and derived rates (`v_operator_po_details_3`). Rows are keyed by id_production_order; filter client-side.",
		example: []any{map[string]any{"id_production_order": 55120, "id_enterprise": 42, "id_equipment": 101,
			"net_production": 8450, "scrap": 37, "running_time": 14400, "downtime": 1260}},
	},
	"/v1/operator-entities": {
		summary:     "Operator entity tree for the tenant",
		description: "One row per tenant with the enterprise, sites, areas, lines (tp_equipment 3), sectors (2) and machines (1) as `{id, name[, position]}` arrays (`v_operator_entities_2`).",
		example: []any{map[string]any{"id_enterprise": 42, "enterprise": []any{exNamed(42, "ACME")},
			"sites": []any{exNamed(7, "Plant 1")}, "areas": []any{exNamed(12, "Packaging")},
			"lines":    []any{map[string]any{"id": 100, "name": "Line 1", "position": 1}},
			"sectors":  []any{},
			"machines": []any{map[string]any{"id": 101, "name": "Filler", "position": 1}}}},
	},
	"/v1/entities-per-user-role": {
		summary:     "Entity tree per user role (operator view)",
		description: "The operator's entity tree per user role (`v_entities_per_user_role_operator`): enterprise, sites, areas and equipment arrays, enriched with each entity's legacy topic prefix.",
		example: []any{map[string]any{"id_enterprise": 42, "id_user_role": 42, "nm_user_role": "ACME",
			"enterprise": []any{exNamed(42, "ACME")}, "sites": []any{exNamed(7, "Plant 1")}}},
	},
	"/v1/language-packs": {
		summary:     "Global i18n language packs",
		description: "Every row of `language_packs`: one per language tag, with the desktop, mobile, operator and overview string bundles.",
		example: []any{map[string]any{"language_tag": "en-US", "id_language_pack": 1,
			"language_pack_operator": map[string]any{"start": "Start"}, "language_pack_desktop": map[string]any{},
			"language_pack_mobile": map[string]any{}, "language_pack_overview": map[string]any{}, "language_pack_operator40": nil}},
	},
	"/v2/events-timeline": {
		summary:     "Event timeline by equipment id",
		description: "Recent machine events for the given id_equipment values (ADR-0061 P3, `serving.events_timeline_by_equipment`; same rows and order as the v1 route).",
		example:     []any{exEventRowV2},
	},
	"/v2/pending-downtime": {
		summary:     "Downtimes still waiting for a reason, by equipment id",
		description: "Unclassified downtime events for the given id_equipment values, newest first (`serving.pending_downtime_by_equipment`).",
		example:     []any{exPendingRowV2},
	},
	"/v2/downtime-reasons": {
		summary:     "Downtime and scrap reason trees by equipment id",
		description: "One row per requested active machine or line (`serving.downtime_reasons_by_equipment`). Line-only reasons rule: a machine inside a line whose downtimes come from its lead machine gets the LINE's downtime tree; scrap reasons stay the machine's own.",
		example:     []any{exReasonsRowV2},
	},
	"/v1/downtime-reasons": {
		summary:      "Downtime and scrap reason trees by topic",
		description:  "Reason trees for the equipment named by `topics` (same line-only reasons rule as /v2). Rows carry id_equipment, downtime_reasons, scrap_reasons and the matched legacy topic string; there is no id_enterprise column on this route.",
		example:      []any{map[string]any{"id_equipment": 101, "downtime_reasons": exReasonTree, "scrap_reasons": exScrapTree}},
		supersededBy: "/v2/downtime-reasons",
	},
}

// endpointArg is the documentation of one args func: its query parameter and
// the exact 400 bodies the func can produce.
type endpointArg struct {
	param  map[string]any
	errors []string
}

// endpointArgParams maps an endpoint's args func to the query parameter it reads
// and its 400 bodies. Funcs are compared by code pointer (top-level funcs only).
// An args func not listed here makes the spec build fail, so a new parser can't
// ship undocumented.
func endpointArgParams(ep endpoint) (*endpointArg, error) {
	if ep.args == nil {
		return nil, nil
	}
	switch reflect.ValueOf(ep.args).Pointer() {
	case reflect.ValueOf(topicsArg).Pointer():
		return &endpointArg{
			param: queryParam("topics", true, strSchema(),
				"Comma-separated equipment topics (`Enterprise/Site/Area/Line[/Machine]`). Narrows WITHIN the caller's tenant; it never selects a tenant. Topics of another tenant simply match nothing.", exTopics),
			errors: []string{`{"error":"missing required query param: topics"}`},
		}, nil
	case reflect.ValueOf(topicArg).Pointer():
		return &endpointArg{
			param:  queryParam("topic", true, strSchema(), "One equipment topic (within the caller's tenant).", exTopic),
			errors: []string{`{"error":"missing required query param: topic"}`},
		}, nil
	case reflect.ValueOf(equipmentIDsArg).Pointer():
		return &endpointArg{
			param: queryParam("equipment", true, strSchema(),
				fmt.Sprintf("Comma-separated positive id_equipment values (at most %d). Identity is id_equipment, never a topic. Ids of another tenant simply match nothing.", maxEquipmentIDs), exEquipment),
			errors: []string{
				`{"error":"missing required query param: equipment"}`,
				fmt.Sprintf(`{"error":"equipment: at most %d ids"}`, maxEquipmentIDs),
				`{"error":"equipment: \"abc\" is not a positive integer id"}`,
			},
		}, nil
	}
	return nil, fmt.Errorf("endpoint %s: args func has no OpenAPI parameter mapping (add it to endpointArgParams)", ep.path)
}

// shimErr is one frozen error a shim can send: status, exact body, and when.
type shimErr struct {
	status int
	body   string
	when   string
}

// shimDoc is what a foreign-contract shim's registry row cannot express.
type shimDoc struct {
	summary     string
	description string
	security    string // secExtHeader or secExtQuery — which credential the shim's auth func reads
	params      []any  // query params beyond the credential (path params are derived)
	envelope    any    // 200 body schema (the frozen envelope)
	example     any    // 200 body example (abridged rows)
	errors      []shimErr
}

// rowsRef is the frozen `data`-style array inside a shim envelope: column order
// is preserved (externalRows) but the columns are the backing object's.
var rowsRef = map[string]any{"$ref": "#/components/schemas/Rows"}

// prop attaches a description to a property schema (the gate requires one on
// every property).
func prop(schema map[string]any, desc string) map[string]any {
	out := make(map[string]any, len(schema)+1)
	for k, v := range schema {
		out[k] = v
	}
	out["description"] = desc
	return out
}

func envelope(props map[string]any, required ...string) map[string]any {
	return map[string]any{"type": "object", "properties": props, "required": required}
}

func rowsProp(desc string) map[string]any {
	return map[string]any{"$ref": "#/components/schemas/Rows", "description": desc}
}

var (
	errHeaderKeyMissing = shimErr{400, "x-api-key is required!", "the `x-api-key` header is absent or empty"}
	errHeaderKeyReject  = shimErr{401, "Unauthorized access", "the key is unknown, or belongs to a tenant other than this shim's bound owner"}
	exAPIKeyQuery       = "<api-key>"
)

func apiKeyQueryParam() map[string]any {
	return queryParam("api_key", false, strSchema(),
		"The integration key (also declared as this operation's security scheme). Missing, empty or the literal string `undefined` count as absent.", exAPIKeyQuery)
}

// shimDocs: one entry per externalShims row, keyed by the registry path
// (Express ":name" form, as the registry declares it). Params, envelopes and
// error bodies are read off the run/auth funcs in external*.go.
var shimDocs = map[string]shimDoc{
	"/ext/neopac/sap-report": {
		summary:     "SAP report rows for one line",
		description: "Resolves `lineCode` to the line's id_equipment within the bound tenant, then returns `serving.sap_site_report(tenant, id_equipment)` in back4's frozen `{data}` envelope.",
		security:    secExtHeader,
		params:      []any{queryParam("lineCode", false, strSchema(), "Line code (cd_equipment), upper-cased before matching, within the bound tenant. Absent or unknown ⇒ 404.", "L01")},
		envelope:    envelope(map[string]any{"data": rowsProp("Report rows, columns in the backing function's order.")}, "data"),
		example: map[string]any{"data": []any{map[string]any{"id_equipment": 101, "werk": "1300", "material": "MAT-1", "menge_soll": 1000,
			"bezeichnung": "Bucket 10 l", "erstellt": "2026-10-12T06:00:00.000Z", "job": "4711", "gyartasi_ido": "12.34", "total_dt": "0.00"}}},
		errors: []shimErr{errHeaderKeyMissing, errHeaderKeyReject, {404, "Line code not found", "no equipment with that cd_equipment in the bound tenant (also when the lookup itself fails)"}},
	},
	"/ext/neopac/sap-report-sync": {
		summary:     "SAP data sync, paginated",
		description: "Pages through `serving.sap_report_data_sync(tenant)` with optional exact filters, in back4's frozen `{page, limit, results, data}` envelope (`results` = rows in this page). Non-numeric `page`/`limit` fall back to the defaults.",
		security:    secExtHeader,
		params: []any{
			queryParam("page", false, intSchema(), "Page number, 1-based (default 1). OFFSET = (page − 1) × limit.", 1),
			queryParam("limit", false, intSchema(), "Page size (default 1000).", 1000),
			queryParam("auftrag", false, strSchema(), "Exact order-number filter.", "4711"),
			queryParam("linie", false, strSchema(), "Exact line filter (upper-cased before matching).", "L01"),
			queryParam("tag", false, strSchema(), "Exact day filter, as stored by the backing function.", "2026-10-12"),
			queryParam("shicht", false, strSchema(), "Exact shift-name filter.", "F"),
			queryParam("shicht_nummer", false, strSchema(), "Exact shift-number filter.", "1"),
		},
		envelope: envelope(map[string]any{
			"page":    prop(intSchema(), "The page that was served."),
			"limit":   prop(intSchema(), "The page size that was applied."),
			"results": prop(intSchema(), "Number of rows in `data`."),
			"data":    rowsProp("Rows of this page."),
		}, "page", "limit", "results", "data"),
		example: map[string]any{"page": 1, "limit": 1000, "results": 1, "data": []any{
			map[string]any{"auftrag": "4711", "sum_labels": "128000", "linie": "L01", "tag": "2026-10-12", "shicht": "F", "shicht_nummer": 1,
				"produktionszeit": "480.00", "geplante_ausfallzeit": "0.00", "gestartet": "2026-10-12T06:00:00.000Z"}}},
		errors: []shimErr{errHeaderKeyMissing, errHeaderKeyReject},
	},
	"/ext/montebello/data-sync": {
		summary:     "Production data sync, paginated",
		description: "Pages through `serving.production_data_sync(tenant)` (optionally one site) in back4's frozen `{page, results, data}` envelope.",
		security:    secExtHeader,
		params: []any{
			queryParam("site", false, strSchema(), "Optional site filter (upper-cased before matching).", "PLANT1"),
			queryParam("page", false, strSchema(), "Page number, 1-based (default 1). Echoed back RAW (as the string sent) in `page`.", "2"),
			queryParam("limit", false, intSchema(), "Page size (default 600).", 600),
		},
		envelope: envelope(map[string]any{
			"page":    map[string]any{"description": "The raw `page` query string, or the integer 1 when absent.", "oneOf": []any{strSchema(), intSchema()}},
			"results": prop(intSchema(), "Number of rows in `data`."),
			"data":    rowsProp("Rows of this page."),
		}, "page", "results", "data"),
		example: map[string]any{"page": "2", "results": 1, "data": []any{
			map[string]any{"site": "PLANT1", "nm_equipment": "Line 3", "uniqueid": "71662", "totalavailablehrsinmin": "480.00",
				"dtimehrsplannedinmin": "0.00", "ts_start": "2026-10-12T06:00:00.000Z"}}},
		errors: []shimErr{errHeaderKeyMissing, errHeaderKeyReject},
	},
	"/ext/montebello/events": {
		summary:     "Downtime events sync",
		description: "Downtime events from `serving.downtime_sync(tenant)`, optionally one site, in back4's frozen `{newData}` envelope. `ts_event`, `ts_end` and `last_update` are second-precision UTC with a literal `Z` (no milliseconds), as back4's moment format emitted.",
		security:    secExtQuery,
		params:      []any{apiKeyQueryParam(), queryParam("site_name", false, strSchema(), "Optional nm_site filter (trimmed, upper-cased).", "PLANT 1")},
		envelope:    envelope(map[string]any{"newData": rowsProp("Downtime event rows.")}, "newData"),
		example: map[string]any{"newData": []any{map[string]any{"nm_site": "PLANT 1", "nm_equipment": "Line 3",
			"ts_event": "2026-10-12T08:12:05Z", "ts_end": "2026-10-12T08:19:40Z", "pack_id": "88", "last_update": "2026-10-12T08:20:01Z"}}},
		errors: []shimErr{
			{400, "api_key is required!", "`api_key` is absent, empty or `undefined`"},
			{401, "Not authorized!", "the key is unknown, or belongs to a tenant other than this shim's bound owner"},
		},
	},
	"/ext/incoplast/events": {
		summary:     "Downtime events in a time window",
		description: "Downtime events of the bound tenant between `startTime` and `endTime`, newest first, in back4's frozen `{newData}` envelope (`pack_id` = id_equipment_event, as a string). `ts_event`, `ts_end` and `last_update` are second-precision UTC with a literal `Z`.",
		security:    secExtQuery,
		params: []any{
			apiKeyQueryParam(),
			queryParam("startTime", false, strSchema(), "Window start, `YYYY-MM-DDTHH:mm:ss` (default: now − 1 month).", "2026-10-01T00:00:00"),
			queryParam("endTime", false, strSchema(), "Window end, `YYYY-MM-DDTHH:mm:ss` (default: now).", "2026-10-13T00:00:00"),
			queryParam("limit", false, intSchema(), "Row limit (default 200).", 200),
		},
		envelope: envelope(map[string]any{"newData": rowsProp("Downtime event rows.")}, "newData"),
		example: map[string]any{"newData": []any{map[string]any{"id_order": 5501, "nm_site": "PLANT 1", "nm_equipment": "Extruder 2",
			"cd_shift": "T1", "ts_event": "2026-10-12T08:12:05Z", "ts_end": "2026-10-12T08:19:40Z", "pack_id": "884213",
			"custom_field": map[string]any{"priority": 10}, "last_update": "2026-10-12T08:20:01Z", "order_number": "5501"}}},
		errors: []shimErr{
			{400, "api_key is required!", "`api_key` is absent, empty or `undefined`"},
			{401, "Unauthorized access", "the key is unknown, or belongs to a tenant other than this shim's bound owner"},
		},
	},
	"/ext/incoplast/jobs": {
		summary:     "Production orders started since a timestamp",
		description: "Production orders with status 2 (running), 3 (finished) or 4 (paused) since `ts_start`, in back4's frozen `{jobs_filtered}` envelope. `ts_start`, `ts_end` and `last_update` are second-precision UTC with a literal `Z`.",
		security:    secExtQuery,
		params: []any{
			apiKeyQueryParam(),
			queryParam("ts_start", false, strSchema(), "Lower bound, `YYYY-MM-DD HH:mm:ss` UTC (default: now − 20 days; `undefined` = absent).", "2026-10-01 00:00:00"),
			queryParam("limit", false, intSchema(), "Row limit (default 100; `undefined` = absent).", 100),
		},
		envelope: envelope(map[string]any{"jobs_filtered": rowsProp("Production-order rows.")}, "jobs_filtered"),
		example: map[string]any{"jobs_filtered": []any{map[string]any{"id_production_order": "9001", "id_order": 778,
			"net_production": 1234.5, "gross_production": 1300, "ts_start": "2026-10-12T06:00:00Z", "ts_end": "2026-10-12T14:00:00Z",
			"id_equipment": 101, "status": 3, "custom_field": map[string]any{"priority": 10}, "last_update": "2026-10-12T14:00:05Z",
			"order_number": "OP-778"}}},
		errors: []shimErr{
			{400, "api_key is required!", "`api_key` is absent, empty or `undefined`"},
			{401, "Unauthorized access", "the key is unknown, or belongs to a tenant other than this shim's bound owner"},
		},
	},
	"/integration/job_data_integration/:id_enterprise": {
		summary:     "Job data for the last N days",
		description: "Job/production data from `serving.data_sync(tenant, days_interval)`, optionally one site, in back4's frozen `{data_integration}` envelope.",
		security:    secExtQuery,
		params: []any{
			apiKeyQueryParam(),
			queryParam("days_interval", true, intSchema(), "Days back, 1–41. Absent or non-numeric counts as 0 (rejected).", 7),
			queryParam("site", false, strSchema(), "Optional site filter (upper-cased before matching).", "PLANT1"),
		},
		envelope: envelope(map[string]any{"data_integration": rowsProp("Job data rows.")}, "data_integration"),
		example: map[string]any{"data_integration": []any{map[string]any{"site": "PLANT1", "nm_equipment": "Extruder 1", "job": "8801",
			"totalavailablehrsinmin": "480.00", "setuphoursinmin": "0.00", "presscnt": "12345",
			"supervisornotes": map[string]any{"note": "setup ok", "approved": true}, "ts_start": "2026-10-12T06:00:00.000Z"}}},
		errors: []shimErr{
			{400, "id is required!", "`api_key` is missing or unknown"},
			{400, "days interval must be between 1 and 41", "`days_interval` is absent, not a number, or outside 1–41"},
			{422, "Invalid id", "the key's enterprise differs from the path `id_enterprise`, or is not this shim's bound owner"},
		},
	},
	"/integration/get-shift-validation/:id_enterprise": {
		summary:     "Shift validation rows for the last N days",
		description: "Per-shift validation rows for the last `days_interval` days, in back4's frozen `{shift_data}` envelope (`ts_value_production` is a date-only string). Every failure, authentication included, is a 500 with a text/html message: this reproduces back4 exactly.",
		security:    secExtQuery,
		params: []any{
			apiKeyQueryParam(),
			queryParam("days_interval", true, intSchema(), "Days back, 1–41. Validated AFTER the site lookup, so a bad site wins.", 7),
			queryParam("site", false, strSchema(), "Optional site suffix used to find the site's topic within the tenant.", "PLANT1"),
		},
		envelope: envelope(map[string]any{"shift_data": rowsProp("Shift validation rows.")}, "shift_data"),
		example: map[string]any{"shift_data": []any{map[string]any{"index1": "7", "id_site": 14, "ts_value_production": "2026-10-12",
			"cd_shift": "T1", "id_order": "5000000001", "txt_validation_notes": map[string]any{"LastConfirm": map[string]any{"note": "checked", "approved": true}},
			"to_delete": false, "order_number": nil}}},
		errors: []shimErr{
			{500, "Not authorized!", "`api_key` missing/unknown, path id not numeric, or the key's enterprise is not the path id / bound owner"},
			{500, "Site does not exist!", "`site` given but no topic of the tenant ends with it"},
			{500, "Enterprise topic not found!", "no `site` and the tenant has no topic at all"},
			{500, "Days interval must be between 1 and 41", "`days_interval` absent, not a number or outside 1–41"},
		},
	},
	"/integration/job_report/:id_enterprise": {
		summary:     "Job report (press counts) for given equipment",
		description: "Job report rows (press counts per production order and shift) for the listed equipment of the bound tenant, in back4's frozen `{job_report}` envelope.",
		security:    secExtQuery,
		params: []any{
			apiKeyQueryParam(),
			queryParam("id_equipment", true, strSchema(),
				"Equipment id list in any of the forms `1,2`, `[1,2]` or `{1,2}`; non-numeric items are ignored. `undefined` counts as absent.", "[101,102]"),
		},
		envelope: envelope(map[string]any{"job_report": rowsProp("Job report rows.")}, "job_report"),
		example: map[string]any{"job_report": []any{map[string]any{"id_equipment": 101, "cd_shift": "T1",
			"ts_value_production": "2026-10-12T06:00:00.000Z", "id_order": 901, "presscount": 4200.5, "ts_start": "2026-10-12T06:00:00.000Z",
			"order_number": "OP-901"}}},
		errors: []shimErr{
			{400, "id_enterprise is required!", "`api_key` is missing or unknown"},
			{400, "id_equipment is required!", "`id_equipment` is absent, empty or `undefined`"},
			{422, "Invalid id", "the key's enterprise differs from the path `id_enterprise`, or is not this shim's bound owner"},
		},
	},
}

// ── Small schema/parameter builders ──────────────────────────────────────────

func strSchema() map[string]any { return map[string]any{"type": "string"} }
func intSchema() map[string]any { return map[string]any{"type": "integer"} }
func dateTimeSchema() map[string]any {
	return map[string]any{"type": "string", "format": "date-time"}
}

func queryParam(name string, required bool, schema map[string]any, desc string, example any) map[string]any {
	return map[string]any{"name": name, "in": "query", "required": required, "schema": schema,
		"description": desc, "example": example}
}

func jsonContent(schema any) map[string]any {
	return map[string]any{"application/json": map[string]any{"schema": schema}}
}

// jsonResp is a 2xx JSON response with an example body.
func jsonResp(desc string, schema any, example any) map[string]any {
	return map[string]any{"description": desc, "content": map[string]any{
		"application/json": map[string]any{"schema": schema, "example": example}}}
}

// mediaExamples renders one `example` or, for several bodies, a named
// `examples` map (Swagger UI shows a dropdown).
func mediaExamples(media map[string]any, bodies []string) map[string]any {
	switch len(bodies) {
	case 0:
	case 1:
		media["example"] = bodies[0]
	default:
		ex := map[string]any{}
		for i, b := range bodies {
			ex[fmt.Sprintf("case%d", i+1)] = map[string]any{"summary": b, "value": b}
		}
		media["examples"] = ex
	}
	return media
}

// errResp is an http.Error response: Content-Type `text/plain; charset=utf-8`,
// body = a JSON-looking line plus a trailing newline. bodies are the exact
// strings the handler can send for this status (without the newline).
func errResp(desc string, bodies ...string) map[string]any {
	return map[string]any{"description": desc, "content": map[string]any{
		"text/plain": mediaExamples(map[string]any{"schema": map[string]any{"$ref": "#/components/schemas/ErrorText"}}, bodies)}}
}

// tenantSecurity is what the auth middleware accepts (auth.go): X-Api-Key OR a
// Cognito Bearer. X-Api-Key wins when both are sent.
func tenantSecurity() []any {
	return []any{map[string]any{secAPIKey: []string{}}, map[string]any{secBearer: []string{}}}
}

// tenantOp stamps the security + 401 every middleware-guarded operation shares.
func tenantOp(tag, summary, desc string, params []any, body any, responses map[string]any) map[string]any {
	responses["401"] = map[string]any{"$ref": "#/components/responses/Unauthorized"}
	op := map[string]any{"tags": []string{tag}, "summary": summary, "description": desc,
		"security": tenantSecurity(), "responses": responses}
	if len(params) > 0 {
		op["parameters"] = params
	}
	if body != nil {
		op["requestBody"] = body
	}
	return op
}

// namedExamples builds a media-type `examples` map from (name, summary, value) triples.
func namedExamples(triples ...any) map[string]any {
	out := map[string]any{}
	for i := 0; i+2 < len(triples); i += 3 {
		out[triples[i].(string)] = map[string]any{"summary": triples[i+1], "value": triples[i+2]}
	}
	return out
}

// operationID derives a stable, unique id from method + path (Swagger UI deep
// links key on it): "get /v1/events-timeline" → "get_v1_events_timeline".
func operationID(method, path string) string {
	id := []rune(method)
	for _, r := range path {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			id = append(id, r)
		} else if id[len(id)-1] != '_' {
			id = append(id, '_')
		}
	}
	return strings.TrimRight(string(id), "_")
}

func sortedKeys[V any](m map[string]V) []string {
	out := keysOf(m)
	sort.Strings(out)
	return out
}

// ── The document ─────────────────────────────────────────────────────────────

const tenantNote = "\n\n**Tenant scoping:** the server binds the caller's tenant (resolved from the credential) as `$1` and drops every other tenant's rows; query parameters only narrow within that tenant. Read-only; 15 s query timeout. The route is mounted without a method restriction, so any HTTP method behaves like GET."

const infoDescription = "Packiot read plane: the Hasura-replacement operator reads, the composable query API " +
	"(named datasets + metric × dimension composer), per-user layouts, the historian (hot + cold archive) reach, " +
	"a service-to-service resolver, and frozen foreign-contract shims for ERP/BI integrations. Everything here is read-only " +
	"except the per-user screen layout (`PUT /v1/screen-config`).\n\n" +
	"## How to call this API\n\n" +
	"- **Auth** — tenant routes take `X-Api-Key: <api-key>` (service/operator keys) **or** `Authorization: Bearer <cognito-id-token>` " +
	"(front4 users). The tenant is always derived from the credential, never from the request. When both are sent, `X-Api-Key` wins and a " +
	"bad key is a 401 (no Bearer fallback). The `/ext/*` and `/integration/*` shims authenticate themselves with an integration key " +
	"(`x-api-key` header or `api_key` query parameter, per operation) bound to one tenant; `/internal/*` takes `X-Internal-Key`.\n" +
	"- **Operator super-admin (dark unless OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED)** — a verified super-admin may read another tenant by " +
	"sending `x-operator-superadmin-token: <cognito-id-token>` plus `?idEnterprise=<target>` alongside the normal credential; any failed check " +
	"silently keeps the home tenant.\n" +
	"- **Base URLs** — see `servers`: `https://refdata.staging.packiot.app` (staging), `https://refdata.prod.packiot.app` (production, " +
	"behind CloudFront), `http://localhost:9104` (local dev). `/openapi.json` and `/metrics` are not routed publicly; fetch the spec from the portal.\n" +
	"- **Content types** — request bodies are `application/json` (≤ 64 KB; longer bodies are cut at 64 KB and then fail to parse). " +
	"Successful responses are `application/json`; most are an array of row objects whose columns are the backing SQL object's (examples are abridged).\n" +
	"- **Errors** — native routes answer `text/plain; charset=utf-8` whose body is a one-line JSON object plus a newline, e.g. " +
	"`{\"error\":\"query failed\"}`. Parse it as JSON if you like, but do not rely on the Content-Type. The shims reproduce back4 byte-for-byte: " +
	"plain-string bodies served as `text/html; charset=utf-8`. 401 messages never say which credential failed.\n" +
	"- **Docs** — the read-only Swagger UI portal is https://api.staging.packiot.app/docs/ (cs-admin SSO). The same document is exported to " +
	"`docs/api/openapi/read-api.openapi.json` in packiot-stack-alpha (`make openapi`; `refdata-api --dump-openapi`)."

// buildOpenAPISpec assembles the document. Pure (no I/O, no env): an error
// means a table row has no hand-written enrichment — openapi_test.go turns that
// into a CI failure, so production never sees it.
func buildOpenAPISpec() (map[string]any, error) {
	paths := map[string]any{}
	add := func(path, method string, op map[string]any) {
		item, _ := paths[path].(map[string]any)
		if item == nil {
			item = map[string]any{}
			paths[path] = item
		}
		op["operationId"] = operationID(method, path)
		item[method] = op
	}

	// 1) The Generation-A endpoints table (main.go).
	for _, ep := range endpoints {
		doc, ok := endpointDocs[ep.path]
		if !ok {
			return nil, fmt.Errorf("endpoint %s has no entry in endpointDocs", ep.path)
		}
		arg, err := endpointArgParams(ep)
		if err != nil {
			return nil, err
		}
		var params []any
		resp := map[string]any{
			"200": jsonResp("Rows as JSON objects (abridged example; the columns are the backing SQL object's). An empty array when nothing matches.", rowsRef, doc.example),
		}
		if arg != nil {
			params = []any{arg.param}
			resp["400"] = errResp("Missing or invalid query parameter.", arg.errors...)
		}
		tag, desc := "operator-v1", doc.description+tenantNote
		if strings.HasPrefix(ep.path, "/v2/") {
			tag = "operator-v2"
		}
		if ep.class == routeGlobalRef {
			tag = "reference"
			desc = doc.description + "\n\n**Scoping:** global reference data — a valid credential is required, but rows are not tenant-filtered. Read-only; 15 s query timeout; any HTTP method behaves like GET."
			resp["500"] = errResp("The query or row decoding failed.", `{"error":"query failed"}`, `{"error":"row scan failed"}`, `{"error":"rows error"}`)
		} else {
			resp["500"] = errResp("The query failed or timed out (15 s).", `{"error":"query failed"}`)
		}
		op := tenantOp(tag, doc.summary, desc, params, nil, resp)
		if doc.supersededBy != "" {
			op["deprecated"] = true
			op["description"] = fmt.Sprintf("**Superseded by `GET %s`** (ADR-0061: identity is id_equipment, not a topic). Kept byte-stable for existing callers.\n\n", doc.supersededBy) + desc
		}
		add(ep.path, "get", op)
	}

	// 2) The composable query API (query.go / datasets.go).
	add("/v1/catalog", "get", tenantOp("query", "List composer vocabulary and every named dataset",
		"Schema metadata for POST /v1/query: the composer's metrics, dimensions and grains (grain → max window), the row cap, and every named "+
			"dataset with its group, description, whether it takes a window (and the max), and its filters. `requires_user_context: true` marks "+
			"datasets that only work with a Bearer token (403 with X-Api-Key). Tenant-independent; a valid credential is still required. "+
			"Any HTTP method behaves like GET.",
		nil, nil, map[string]any{
			"200": jsonResp("The catalog (example abridged to two datasets).", map[string]any{"type": "object", "properties": map[string]any{
				"metrics":    prop(map[string]any{"type": "array", "items": strSchema()}, "Composer metric names (unordered)."),
				"dimensions": prop(map[string]any{"type": "array", "items": strSchema()}, "Composer dimension names (unordered)."),
				"grains":     prop(map[string]any{"type": "object", "additionalProperties": strSchema()}, "Grain → maximum window (Go duration string)."),
				"row_limit":  prop(intSchema(), "Row cap applied to every composer query."),
				"datasets": prop(map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "object"}},
					"Dataset name → {group, description, windowed, filters, max_window?, requires_user_context?}. Filter values: `ids` (array of integer ids), `id (required)`, `enum: a|b (default a)`, `bool (default false)`, `date YYYY-MM-DD or datetime (required)`."),
			}}, map[string]any{
				"metrics": sortedKeys(metrics), "dimensions": sortedKeys(dimensions),
				"grains": map[string]any{"1min": "168h0m0s", "1hour": "2160h0m0s"}, "row_limit": queryRowLimit,
				"datasets": map[string]any{
					"production-flow": map[string]any{"group": "production-flow", "description": "Production flow series", "windowed": true, "max_window": "2160h0m0s",
						"filters": map[string]any{"sites": "ids", "areas": "ids", "equipments": "ids", "shifts": "ids", "teams": "ids", "time_grain": "enum: day|hour|week|month (default day)"}},
					"overview-job-info": map[string]any{"group": "overview-detail", "description": "Current job info for one equipment", "windowed": false,
						"filters": map[string]any{"equipment": "id (required)"}},
				},
			}),
		}))

	add("/v1/query", "post", tenantOp("query", "Run a named dataset or a metric × dimension query",
		"Two body shapes share the route.\n\n"+
			"- **Named dataset** — a body with `dataset` runs one allowlisted query from the registry (GET /v1/catalog lists names, windows and filters). "+
			"Unknown filters or out-of-enum values are rejected; the shared row cap is applied. Results are cached per tenant + query for a short TTL "+
			"(Redis cache-aside, fail-open), so identical polls within the TTL return the same bytes. Coverage headers say how far back the dataset's "+
			"hot data reaches.\n"+
			"- **Composer** — `metrics` × `dimensions` over a continuous aggregate at `grain` for [`from`, `to`), at most "+fmt.Sprint(queryRowLimit)+
			" rows; never cached. A window older than the aggregate's retention is a 422 pointing at /v1/historian/*.\n\n"+
			"Body ≤ 64 KB. 40 s query timeout. Tenant-scoped like every native route (the tenant is never read from the body). "+
			"Datasets flagged `requires_user_context` need a Bearer token. Any HTTP method is accepted; POST is the contract.",
		nil,
		map[string]any{"required": true, "content": map[string]any{"application/json": map[string]any{
			"schema": map[string]any{"oneOf": []any{
				map[string]any{"$ref": "#/components/schemas/DatasetQuery"},
				map[string]any{"$ref": "#/components/schemas/ComposerQuery"},
			}},
			"examples": namedExamples(
				"windowedDataset", "Windowed dataset with id filters",
				map[string]any{"dataset": "production-flow", "window": map[string]any{"from": "2026-10-01", "to": "2026-10-08"},
					"filters": map[string]any{"sites": []int{7}, "equipments": []int{101, 102}, "time_grain": "day"}},
				"singleEquipmentDataset", "Dataset that requires one equipment id",
				map[string]any{"dataset": "overview-job-info", "filters": map[string]any{"equipment": 101}},
				"composer", "Composer: hourly net production per equipment",
				map[string]any{"metrics": []string{"net_production", "scrap"}, "dimensions": []string{"equipment"}, "grain": "1hour",
					"from": "2026-10-12T00:00:00Z", "to": "2026-10-13T00:00:00Z", "filters": map[string]any{"equipment": []int{101, 102}}},
			),
		}}},
		map[string]any{
			"200": map[string]any{"description": "Rows as JSON objects (an empty array when nothing matches). Dataset columns are the backing object's; composer columns are `ts_value`, the requested dimensions, then the metrics.",
				"content": map[string]any{"application/json": map[string]any{"schema": rowsRef, "examples": namedExamples(
					"composer", "Composer result",
					[]any{map[string]any{"ts_value": "2026-10-12T08:00:00Z", "equipment": 101, "net_production": 1180, "scrap": 6}},
					"dataset", "Dataset result (abridged)",
					[]any{map[string]any{"ts_value": "2026-10-01", "id_equipment": 101, "net_production": 25410, "gross_production": 25820}},
				)}},
				"headers": map[string]any{
					"X-Data-Hot-Floor": map[string]any{"description": "Dataset path only: the oldest timestamp the dataset still holds (RFC 3339, UTC).", "schema": strSchema(), "example": "2026-07-15T00:00:00Z"},
					"X-Data-Truncated": map[string]any{"description": "Dataset path only: `true` when the window starts before the hot floor (older rows are missing).", "schema": strSchema(), "example": "true"},
					"Warning":          map[string]any{"description": "Dataset path only: a 299 warning accompanying X-Data-Truncated, naming the floor and where deep history lives.", "schema": strSchema(), "example": `299 read-api "window starts before 2026-07-15T00:00:00Z: silver.equipment_values keeps 90 days; older rows are not in this dataset (deep history: /v1/historian/*)"`},
				}},
			"400": errResp("Malformed body, or the request fails validation (unknown dataset/metric/dimension/grain/filter, bad window, window over budget).",
				`{"error":"bad request body"}`,
				`{"error":"unknown dataset \"production-flw\""}`,
				`{"error":"dataset \"production-flow\" requires window {from,to} with to > from"}`,
				`{"error":"window exceeds 2160h0m0s budget for dataset \"production-flow\""}`,
				`{"error":"dataset \"overview-job-info\" does not accept filter \"sites\""}`,
				`{"error":"filter \"time_grain\" must be one of day|hour|week|month"}`,
				`{"error":"unknown metric \"oee\""}`,
				`{"error":"window exceeds 168h0m0s budget for grain 1min"}`),
			"413": errResp("The body exceeds 64 KB.", `{"error":"payload too large"}`),
			"403": errResp("A per-user-role dataset (`requires_user_context`) was called without a user identity (X-Api-Key, or a user without a role).",
				`{"error":"dataset requires user context (front4 Firebase JWT); not available via X-Api-Key"}`),
			"422": errResp("Composer only: the window starts before the aggregate's retention floor.",
				`{"error":"window starts before 2026-07-15T00:00:00Z: agg_equipment_values_1hour keeps 90 days; for older data use /v1/historian/production-series"}`),
			"500": errResp("The query failed or timed out (40 s).", `{"error":"query failed"}`),
		}))

	userScreen := []any{
		queryParam("user", true, strSchema(), "User id whose layout to read/write. Selects a row WITHIN the caller's tenant; it is not an authorization check.", "1234"),
		queryParam("screen", true, strSchema(), "Screen key (for dashboards: the dashboard_id).", "mission-control"),
	}
	exLayout := map[string]any{"columns": 3, "widgets": []any{map[string]any{"id": "oee-gauge", "x": 0, "y": 0, "w": 1, "h": 1}}}
	add("/v1/screen-config", "get", tenantOp("query", "Read a saved per-user screen layout",
		"Returns the stored layout JSON for (tenant, user, screen) from `identity.user_screen_config`, or `{}` when none is stored. "+
			"A database error is a 500, never `{}`. A non-GET/PUT method returns 405 `{\"error\":\"GET or PUT\"}` (after the user/screen check)."+tenantNote,
		userScreen, nil, map[string]any{
			"200": jsonResp("The stored layout JSON exactly as saved, or `{}` when no layout is stored.", map[string]any{"description": "Any JSON value the client saved."}, exLayout),
			"400": errResp("`user` or `screen` is missing.", `{"error":"user and screen query params required"}`),
			"500": errResp("The read failed (database error).", `{"error":"query failed"}`),
		}))
	add("/v1/screen-config", "put", tenantOp("query", "Save a per-user screen layout",
		"Upserts the request body as the layout for (tenant, user, screen) in `identity.user_screen_config` (last write wins; idempotent for the same body). "+
			"The body may be any valid JSON up to 64 KB. Also used as the per-user override of GET /v1/dashboard-config (screen = dashboard_id). "+
			"Tenant-scoped: the tenant comes from the credential.",
		userScreen,
		map[string]any{"required": true, "content": map[string]any{"application/json": map[string]any{
			"schema":  map[string]any{"description": "Any valid JSON, ≤ 64 KB. A JSON object is recommended (dashboard overrides merge only objects)."},
			"example": exLayout}}},
		map[string]any{
			"200": jsonResp("Stored.", map[string]any{"type": "object", "properties": map[string]any{"ok": map[string]any{"type": "boolean", "description": "Always `true` on success."}}, "required": []string{"ok"}}, map[string]any{"ok": true}),
			"400": errResp("`user`/`screen` missing, or the body is not valid JSON ≤ 64 KB.",
				`{"error":"user and screen query params required"}`, `{"error":"config must be valid JSON <= 64KB"}`),
			"413": errResp("The body exceeds 64 KB.", `{"error":"payload too large"}`),
			"500": errResp("The upsert failed.", `{"error":"store failed"}`),
		}))

	add("/v1/dashboard-config", "get", tenantOp("query", "Resolve a dashboard config (baseline plus user override)",
		"Resolves the dashboard document front4 renders: the tenant's latest `dashboard_config` baseline for `dashboard_id`, shallow-merged "+
			"(`baseline || override`, override keys win) with the user's `identity.user_screen_config` row for screen = `dashboard_id`. "+
			"`status` is `ok`, `not_found` (no baseline for this tenant) or `invalid` (the stored config is not a JSON object). "+
			"10 s timeout. A non-GET method returns 405 `{\"error\":\"GET only\"}`."+
			"\n\n**Tenant scoping:** both reads are fenced to the caller's tenant; `user` only selects a row within it.",
		[]any{
			queryParam("dashboard_id", true, strSchema(), "Dashboard id.", "overview"),
			queryParam("user", false, strSchema(), "Optional user id whose override to merge; absent ⇒ baseline only.", "1234"),
		}, nil, map[string]any{
			"200": map[string]any{"description": "Resolution envelope (always 200, even when nothing is found).",
				"content": map[string]any{"application/json": map[string]any{
					"schema": map[string]any{"type": "object", "required": []string{"status"}, "properties": map[string]any{
						"status":  prop(map[string]any{"type": "string", "enum": []string{"ok", "not_found", "invalid"}}, "Resolution outcome."),
						"config":  prop(map[string]any{"type": "object"}, "The merged config (status ok only)."),
						"version": prop(intSchema(), "Baseline version that was served (status ok only)."),
						"issues": prop(map[string]any{"type": "array", "items": envelope(map[string]any{
							"path":    prop(strSchema(), "Where the problem is (`(root)` for the whole document)."),
							"message": prop(strSchema(), "Human-readable problem."),
						}, "path", "message")}, "Why the config is invalid (status invalid only)."),
					}},
					"examples": namedExamples(
						"ok", "Resolved", map[string]any{"status": "ok", "config": map[string]any{"layout": "grid", "widgets": []any{"oee-gauge"}}, "version": 3},
						"notFound", "No baseline for this tenant", map[string]any{"status": "not_found"},
						"invalid", "Stored config is not an object", map[string]any{"status": "invalid", "issues": []any{map[string]any{"path": "(root)", "message": "stored config is not a JSON object"}}},
					)}}},
			"400": errResp("`dashboard_id` is missing.", `{"error":"dashboard_id query param required"}`),
			"500": errResp("The query failed or timed out.", `{"error":"query failed"}`),
		}))

	// 3) The historian gateway reach (historian.go).
	for _, h := range []struct {
		path, summary, desc string
		example             any
	}{
		{"/v1/historian/production-series", "Daily gross and net production per equipment",
			"Daily gross/net production per equipment over the hot + cold archive (cold daily rollup + hot hourly rollup, whole UTC days). Rows: `day, id_equipment, gross_production, net_production`.",
			[]any{map[string]any{"day": "2024-03-01", "id_equipment": 101, "gross_production": 25820, "net_production": 25410}}},
		{"/v1/historian/downtime-series", "Daily downtime per equipment, planned versus unplanned",
			"Daily downtime per equipment over the hot + cold archive, split by `planned_downtime`. Rows: `day, id_equipment, planned_downtime, event_count, downtime_seconds`.",
			[]any{map[string]any{"day": "2024-03-01", "id_equipment": 101, "planned_downtime": false, "event_count": 14, "downtime_seconds": 5320}}},
	} {
		add(h.path, "post", tenantOp("historian", h.summary,
			h.desc+" For windows older than the hot tier (the composer and datasets return 422 / X-Data-Truncated there).\n\n"+
				"`from`/`to` must be RFC 3339; the window is [from, to), at most ~5 years, at most "+fmt.Sprint(histRowLimit)+" rows. Body ≤ 64 KB. "+
				"60 s timeout. Validation runs before the gateway check, so a bad window is 400 even when the historian is down. "+
				"A non-POST method returns 405 `{\"error\":\"POST only\"}`.\n\n**Tenant scoping:** rows are always the caller's tenant; `equipment` only narrows.",
			nil,
			map[string]any{"required": true, "content": map[string]any{"application/json": map[string]any{
				"schema":  map[string]any{"$ref": "#/components/schemas/HistorianWindow"},
				"example": map[string]any{"from": "2024-01-01T00:00:00Z", "to": "2024-04-01T00:00:00Z", "equipment": []int{101, 102}}}}},
			map[string]any{
				"200": jsonResp("Daily rows, ordered by day and equipment.", rowsRef, h.example),
				"400": errResp("Malformed body (including a non-RFC 3339 bound), from ≥ to, or the window exceeds the budget.",
					`{"error":"bad request body"}`, `{"error":"invalid window: require from < to (RFC3339)"}`,
					fmt.Sprintf(`{"error":"window exceeds %s historian budget"}`, histMaxWindow)),
				"413": errResp("The body exceeds 64 KB.", `{"error":"payload too large"}`),
				"500": errResp("The historian query failed or timed out (60 s).", `{"error":"historian query failed"}`),
				"503": errResp("The historian gateway is not configured on this deployment.", `{"error":"historian gateway not configured"}`),
			}))
	}

	// 4) The service-to-service resolver (internal.go).
	add("/internal/resolve-device", "get", map[string]any{
		"tags":    []string{"internal"},
		"summary": "Resolve a device_key to its active id_equipment",
		"description": "Used by the edge transformer at SparkPlug birth (ADR-0046): returns the active `core.device_bindings` row for an opaque device key. " +
			"A 404 is the normal \"not bound (yet)\" answer, not a fault. Not tenant-scoped by credential: the key is a shared service secret and " +
			"`enterprise` is an optional belt-and-braces filter. 5 s timeout. A non-GET method returns 405 `{\"error\":\"method not allowed\"}` with `Allow: GET`. " +
			"Inert (every call 401) until INTERNAL_API_KEY is set.",
		"security": []any{map[string]any{secInternalKey: []string{}}},
		"parameters": []any{
			queryParam("device_key", true, map[string]any{"type": "string", "pattern": deviceKeyRe.String()}, "Opaque device key: `dk_` + 32 lowercase hex characters.", exDeviceKey),
			queryParam("enterprise", false, intSchema(), "Optional positive id_enterprise; when given, the binding must belong to it.", 42),
		},
		"responses": map[string]any{
			"200": jsonResp("The binding.", envelope(map[string]any{
				"id_equipment":  prop(intSchema(), "The equipment the key is bound to."),
				"id_enterprise": prop(intSchema(), "That equipment's tenant."),
			}, "id_equipment", "id_enterprise"), map[string]any{"id_equipment": 101, "id_enterprise": 42}),
			"400": errResp("`device_key` missing or not a `dk_` key, or `enterprise` not a positive integer.",
				`{"error":"device_key is required"}`, `{"error":"device_key must be an opaque dk_<32 hex> key (ADR-0061)"}`,
				`{"error":"enterprise, when given, must be a positive integer"}`),
			"401": errResp("Missing or wrong `X-Internal-Key`, or INTERNAL_API_KEY unset (endpoint inert).", `{"error":"missing or invalid internal credentials"}`),
			"404": errResp("No active binding for the key (within `enterprise`, when given).", `{"error":"device_key not mapped to an active id_equipment"}`),
			"500": errResp("The query failed or timed out.", `{"error":"query failed"}`),
		},
	})

	// 5) The foreign-contract shims (external.go registry).
	for _, sh := range externalShims {
		doc, ok := shimDocs[sh.path]
		if !ok {
			return nil, fmt.Errorf("external shim %s has no entry in shimDocs", sh.path)
		}
		if doc.security != secExtHeader && doc.security != secExtQuery {
			return nil, fmt.Errorf("external shim %s: security must be %s or %s", sh.path, secExtHeader, secExtQuery)
		}
		var params []any
		for _, seg := range strings.Split(sh.path, "/") {
			if isWildcardSeg(seg) {
				name := strings.Trim(seg, ":{}")
				params = append(params, map[string]any{"name": name, "in": "path", "required": true, "schema": intSchema(), "example": 42,
					"description": "The tenant id. Must equal the api_key's own enterprise and the shim's bound owner."})
			}
		}
		params = append(params, doc.params...)
		resp := map[string]any{"200": map[string]any{
			"description": "back4's frozen envelope (`application/json; charset=utf-8`, no HTML escaping). Row columns and their order are the backing object's; the example is abridged (most rows also carry the equipment's legacy SparkPlug topic string). Other timestamps are `YYYY-MM-DDTHH:mm:ss.000Z`.",
			"content":     map[string]any{"application/json": map[string]any{"schema": doc.envelope, "example": doc.example}},
		}}
		byStatus := map[int][]shimErr{}
		for _, e := range doc.errors {
			byStatus[e.status] = append(byStatus[e.status], e)
		}
		byStatus[500] = append(byStatus[500], shimErr{500, "", ""}) // marker: the shared encode failure
		for status, errs := range byStatus {
			var whens, bodies []string
			for _, e := range errs {
				if e.body == "" {
					continue
				}
				whens = append(whens, fmt.Sprintf("`%s` — %s", e.body, e.when))
				bodies = append(bodies, e.body)
			}
			content := map[string]any{}
			desc := strings.Join(whens, "; ")
			if len(bodies) > 0 {
				content["text/html"] = mediaExamples(map[string]any{"schema": strSchema()}, bodies)
			}
			if status == 500 {
				content["text/plain"] = mediaExamples(map[string]any{"schema": map[string]any{"$ref": "#/components/schemas/ErrorText"}}, []string{`{"error":"encode failed"}`})
				if desc != "" {
					desc += "; "
				}
				desc += "text/plain `{\"error\":\"encode failed\"}` — the envelope could not be encoded (not expected in practice)"
			}
			resp[fmt.Sprint(status)] = map[string]any{"description": desc + ".", "content": content}
		}
		add(muxPattern(sh.path), "get", map[string]any{
			"tags":    []string{"external"},
			"summary": doc.summary,
			"description": doc.description + fmt.Sprintf("\n\nAnti-corruption shim (ADR-0031) reproducing a frozen back4 contract for consumer %q. "+
				"Self-authenticating: the key must resolve to the shim's bound owner tenant (%s; unset ⇒ every call is rejected). "+
				"Error bodies are back4's exact strings as `text/html; charset=utf-8`. A database error is swallowed like back4 did: the "+
				"envelope comes back with no rows (or, for lookups, the not-found error). Read-only; 15 s timeout; any HTTP method behaves like GET.",
				sh.consumer, sh.ownerEnv),
			"security":   []any{map[string]any{doc.security: []string{}}},
			"parameters": params,
			"responses":  resp,
		})
	}

	return map[string]any{
		"openapi": "3.1.0",
		"info": map[string]any{
			"title":       "read-api (refdata-api)",
			"version":     "1.0.0",
			"description": infoDescription,
		},
		"servers": openAPIServers,
		"tags": []any{
			map[string]any{"name": "operator-v1", "description": "Operator-app reads keyed by equipment topic (Hasura replacement). The ones with a /v2 twin are deprecated."},
			map[string]any{"name": "operator-v2", "description": "Operator-app reads keyed by id_equipment (ADR-0061 P3)."},
			map[string]any{"name": "reference", "description": "Global reference data (authenticated, not tenant-filtered)."},
			map[string]any{"name": "query", "description": "Composable query API: catalog, named datasets, composer, per-user layouts and dashboard configs (ADR-0015, ADR-0029)."},
			map[string]any{"name": "historian", "description": "Long-range daily series over the hot + cold archive via the historian gateway."},
			map[string]any{"name": "internal", "description": "Service-to-service endpoints (shared secret; not for clients)."},
			map[string]any{"name": "external", "description": "Frozen back4 contracts consumed by client ERP/BI integrations (ADR-0031). Byte-compatible with the legacy API."},
		},
		"paths": paths,
		"components": map[string]any{
			"securitySchemes": map[string]any{
				secAPIKey: map[string]any{"type": "apiKey", "in": "header", "name": "X-Api-Key",
					"description": "Operator/service key (QUERY_API_KEYS key:customer_id map, auth.go). Authoritative when present: a bad key 401s, no Bearer fallback."},
				secBearer: map[string]any{"type": "http", "scheme": "bearer", "bearerFormat": "JWT",
					"description": "Cognito ID token (COGNITO_ISSUER / COGNITO_CLIENT_ID). The tenant and user role come from the users row linked to the token (auth_firebase.go, auth_cognito.go). Used when no X-Api-Key is sent."},
				secExtHeader: map[string]any{"type": "apiKey", "in": "header", "name": "x-api-key",
					"description": "Foreign-contract shims (external.go headerAPIKeyAuth): same QUERY_API_KEYS map, but the key must resolve to the shim's bound owner. Missing → 400, unknown/other tenant → 401, text/html."},
				secExtQuery: map[string]any{"type": "apiKey", "in": "query", "name": "api_key",
					"description": "Foreign-contract shims that take the key as a query param (queryAPIKeyAuth, /integration/* ladders). Same map, owner-bound."},
				secInternalKey: map[string]any{"type": "apiKey", "in": "header", "name": "X-Internal-Key",
					"description": "Shared service secret (INTERNAL_API_KEY, internal.go). Unset ⇒ every request 401s."},
			},
			"responses": map[string]any{
				"Unauthorized": errResp("No credential, an unknown X-Api-Key, or an invalid/expired Bearer token (or one whose user maps to no active tenant). The message never says which.",
					`{"error":"missing or invalid credentials"}`),
			},
			"schemas": componentSchemas(),
		},
	}, nil
}

// componentSchemas holds the reusable bodies. The enums are read off the live
// registries, so they track the code.
func componentSchemas() map[string]any {
	dims := sortedKeys(dimensions)
	filterProps := map[string]any{}
	for _, d := range dims {
		filterProps[d] = prop(map[string]any{"type": "array", "items": intSchema()}, fmt.Sprintf("Allowed %s ids (`%s = ANY(...)`).", d, dimensions[d]))
	}
	return map[string]any{
		"Rows": map[string]any{"type": "array", "items": map[string]any{"type": "object", "additionalProperties": true},
			"description": "Result rows as JSON objects; the columns are whatever the backing view/function returns."},
		"ErrorText": map[string]any{"type": "string", "examples": []string{`{"error":"query failed"}`},
			"description": "http.Error body: a one-line JSON object followed by a newline, served as `text/plain; charset=utf-8`."},
		"DatasetQuery": map[string]any{"type": "object", "required": []string{"dataset"},
			"description": "Named-dataset request. The set of names and each one's filters are listed by GET /v1/catalog.",
			"properties": map[string]any{
				"dataset": prop(map[string]any{"type": "string", "enum": sortedKeys(datasets)}, "Dataset name."),
				"window": prop(map[string]any{"type": "object", "required": []string{"from", "to"}, "properties": map[string]any{
					"from": prop(strSchema(), "Window start (inclusive)."),
					"to":   prop(strSchema(), "Window end; must be after `from`."),
				}}, "Required for windowed datasets, rejected otherwise. Bounds accept YYYY-MM-DD, YYYY-MM-DD HH:mm, YYYY-MM-DD HH:mm:ss or RFC 3339; the span must fit the dataset's max_window."),
				"filters": prop(map[string]any{"type": "object", "additionalProperties": true},
					"Per-dataset filters (GET /v1/catalog → datasets[name].filters): id lists as integer arrays, single ids as integers, enums as lower-case strings, booleans, dates as strings."),
			}},
		"ComposerQuery": map[string]any{"type": "object", "required": []string{"metrics", "grain", "from", "to"},
			"description": "Metric × dimension composition over one continuous aggregate.",
			"properties": map[string]any{
				"metrics":    prop(map[string]any{"type": "array", "minItems": 1, "items": map[string]any{"type": "string", "enum": sortedKeys(metrics)}}, "Metrics to aggregate (sums of increments; avg_speed is an average)."),
				"dimensions": prop(map[string]any{"type": "array", "items": map[string]any{"type": "string", "enum": dims}}, "Group-by dimensions, returned as columns of the same name."),
				"grain":      prop(map[string]any{"type": "string", "enum": sortedKeys(grains)}, "Bucket size; picks the aggregate and its max window (1min: 7 days, 1hour: 90 days)."),
				"from":       prop(dateTimeSchema(), "Window start, RFC 3339 (inclusive)."),
				"to":         prop(dateTimeSchema(), "Window end, RFC 3339 (exclusive); must be after `from`."),
				"filters":    prop(map[string]any{"type": "object", "properties": filterProps, "additionalProperties": false}, "Dimension → allowed ids."),
			}},
		"HistorianWindow": map[string]any{"type": "object", "required": []string{"from", "to"},
			"description": "Historian window request.",
			"properties": map[string]any{
				"from":      prop(dateTimeSchema(), "Window start, RFC 3339 (inclusive)."),
				"to":        prop(dateTimeSchema(), "Window end, RFC 3339 (exclusive); at most ~5 years after `from`."),
				"equipment": prop(map[string]any{"type": "array", "items": intSchema()}, "Optional id_equipment filter; empty ⇒ all of the tenant's equipment."),
			}},
	}
}

// openAPIDocumentJSON builds and marshals the document. It is the single byte
// source for GET /openapi.json, `refdata-api --dump-openapi` (the committed wiki
// export, `make openapi`) and the completeness gate, so all three agree. The
// output is indented, not HTML-escaped and newline-terminated so the committed export diffs well.
func openAPIDocumentJSON() ([]byte, error) {
	spec, err := buildOpenAPISpec()
	if err != nil {
		return nil, err
	}
	// No HTML escaping: placeholders like "<api-key>" stay readable in the
	// committed export. Encode appends the trailing newline.
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(spec); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// dumpOpenAPI writes the document to out (`refdata-api --dump-openapi`). Pure:
// no DB, no network, no env — the spec is built from the route tables alone.
func dumpOpenAPI(out io.Writer) error {
	b, err := openAPIDocumentJSON()
	if err != nil {
		return err
	}
	_, err = out.Write(b)
	return err
}

// openAPIHandler marshals the document once, on first request, and serves the
// cached bytes. A build error (unreachable once openapi_test.go passes) is a 500,
// never a crash.
func openAPIHandler() http.HandlerFunc {
	var (
		once sync.Once
		body []byte
		err  error
	)
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, `{"error":"GET only"}`, http.StatusMethodNotAllowed)
			return
		}
		once.Do(func() { body, err = openAPIDocumentJSON() })
		if err != nil {
			http.Error(w, `{"error":"openapi build failed"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}
}
