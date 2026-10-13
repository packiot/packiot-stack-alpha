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
	"encoding/json"
	"fmt"
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

// ── Hand-written enrichment, keyed by path ───────────────────────────────────

// endpointSummaries: one line per `endpoints` row. The table carries path, SQL,
// class and args; the gate requires a summary for every row.
var endpointSummaries = map[string]string{
	"/v1/events-timeline":           "Event timeline rows for the given equipment topics (serving.events_timeline).",
	"/v1/pending-downtime":          "Downtime events still waiting for a reason, for the given equipment topics.",
	"/v1/shift-hours":               "Shift hours for one equipment topic.",
	"/v1/shift-hours-by-enterprise": "Shift hours for one equipment topic (enterprise variant; the enterprise is the caller's tenant).",
	"/v1/day-week-begin":            "Day/week begin offsets for one equipment topic.",
	"/v1/operator-po-list":          "Operator production-order list (v_operator_po_list_setup_4).",
	"/v2/operator-po-list":          "Operator production-order list by id_equipment (ADR-0061 P3).",
	"/v1/operator-po-details":       "Operator production-order details (v_operator_po_details_3).",
	"/v1/operator-entities":         "Operator entity tree (v_operator_entities_2).",
	"/v1/entities-per-user-role":    "Entities per user role for the operator (v_entities_per_user_role_operator).",
	"/v1/language-packs":            "Global i18n language packs (tenant-independent, still authenticated).",
	"/v2/events-timeline":           "Event timeline rows by id_equipment (ADR-0061 P3).",
	"/v2/pending-downtime":          "Downtime events still waiting for a reason, by id_equipment (ADR-0061 P3).",
	"/v2/downtime-reasons":          "Downtime + scrap reason trees by id_equipment (line-only reasons rule).",
	"/v1/downtime-reasons":          "Downtime + scrap reason trees for the given equipment topics (line-only reasons rule).",
}

// endpointArgParams maps an endpoint's args func to the query parameters it
// reads. Funcs are compared by code pointer (top-level funcs only). An args func
// not listed here makes the spec build fail, so a new parser can't ship
// undocumented.
func endpointArgParams(ep endpoint) ([]any, error) {
	if ep.args == nil {
		return nil, nil
	}
	switch reflect.ValueOf(ep.args).Pointer() {
	case reflect.ValueOf(topicsArg).Pointer():
		return []any{queryParam("topics", true, strSchema(), "Comma-separated equipment topics. Narrows WITHIN the caller's tenant; it never selects a tenant.")}, nil
	case reflect.ValueOf(topicArg).Pointer():
		return []any{queryParam("topic", true, strSchema(), "One equipment topic (within the caller's tenant).")}, nil
	case reflect.ValueOf(equipmentIDsArg).Pointer():
		return []any{queryParam("equipment", true, strSchema(),
			fmt.Sprintf("Comma-separated positive id_equipment values (at most %d). Identity is id_equipment, never a topic.", maxEquipmentIDs))}, nil
	}
	return nil, fmt.Errorf("endpoint %s: args func has no OpenAPI parameter mapping (add it to endpointArgParams)", ep.path)
}

// shimDoc is what a foreign-contract shim's registry row cannot express.
type shimDoc struct {
	summary  string
	security string // secExtHeader or secExtQuery — which credential the shim's auth func reads
	params   []any  // query params beyond the credential (path params are derived)
	envelope any    // 200 body schema (the frozen envelope)
	errors   map[int]string
}

// rowsRef is the frozen `data`-style array inside a shim envelope: column order
// is preserved (externalRows) but the columns are the backing object's.
var rowsRef = map[string]any{"$ref": "#/components/schemas/Rows"}

func envelope(props map[string]any, required ...string) map[string]any {
	return map[string]any{"type": "object", "properties": props, "required": required}
}

// shimDocs: one entry per externalShims row, keyed by the registry path
// (Express ":name" form, as the registry declares it). Params, envelopes and
// error bodies are read off the run/auth funcs in external*.go.
var shimDocs = map[string]shimDoc{
	"/ext/neopac/sap-report": {
		summary:  "NEOPAC SAP report for one line (frozen back4 contract).",
		security: secExtHeader,
		params:   []any{queryParam("lineCode", false, strSchema(), "Line code (cd_equipment, upper-cased) resolved within the bound tenant.")},
		envelope: envelope(map[string]any{"data": rowsRef}, "data"),
		errors: map[int]string{400: "x-api-key is required!", 401: "Unauthorized access",
			404: "Line code not found"},
	},
	"/ext/neopac/sap-report-sync": {
		summary:  "NEOPAC SAP data sync, paginated (frozen back4 contract).",
		security: secExtHeader,
		params: []any{
			queryParam("page", false, intSchema(), "Page number (default 1)."),
			queryParam("limit", false, intSchema(), "Page size (default 1000)."),
			queryParam("auftrag", false, strSchema(), "Optional exact filter."),
			queryParam("linie", false, strSchema(), "Optional exact filter (upper-cased)."),
			queryParam("tag", false, strSchema(), "Optional exact filter."),
			queryParam("shicht", false, strSchema(), "Optional exact filter."),
			queryParam("shicht_nummer", false, strSchema(), "Optional exact filter."),
		},
		envelope: envelope(map[string]any{"page": intSchema(), "limit": intSchema(),
			"results": intSchema(), "data": rowsRef}, "page", "limit", "results", "data"),
		errors: map[int]string{400: "x-api-key is required!", 401: "Unauthorized access"},
	},
	"/ext/montebello/data-sync": {
		summary:  "Montebello production data sync, paginated (frozen back4 contract).",
		security: secExtHeader,
		params: []any{
			queryParam("site", false, strSchema(), "Optional site filter (upper-cased)."),
			queryParam("page", false, strSchema(), "Page number (default 1). Echoed back RAW in `page`."),
			queryParam("limit", false, intSchema(), "Page size (default 600)."),
		},
		envelope: envelope(map[string]any{
			"page":    map[string]any{"description": "The raw `page` query value (string), or the integer 1 when absent."},
			"results": intSchema(), "data": rowsRef}, "page", "results", "data"),
		errors: map[int]string{400: "x-api-key is required!", 401: "Unauthorized access"},
	},
	"/ext/montebello/events": {
		summary:  "Montebello downtime events (frozen back4 contract).",
		security: secExtQuery,
		params:   []any{queryParam("site_name", false, strSchema(), "Optional nm_site filter (upper-cased).")},
		envelope: envelope(map[string]any{"newData": rowsRef}, "newData"),
		errors:   map[int]string{400: "api_key is required!", 401: "Not authorized!"},
	},
	"/ext/incoplast/events": {
		summary:  "Incoplast downtime events (frozen back4 contract).",
		security: secExtQuery,
		params: []any{
			queryParam("startTime", false, strSchema(), "Window start, YYYY-MM-DDTHH:mm:ss (default now − 1 month)."),
			queryParam("endTime", false, strSchema(), "Window end, YYYY-MM-DDTHH:mm:ss (default now)."),
			queryParam("limit", false, intSchema(), "Row limit (default 200)."),
		},
		envelope: envelope(map[string]any{"newData": rowsRef}, "newData"),
		errors:   map[int]string{400: "api_key is required!", 401: "Unauthorized access"},
	},
	"/ext/incoplast/jobs": {
		summary:  "Incoplast production orders (status 2/3/4) since ts_start (frozen back4 contract).",
		security: secExtQuery,
		params: []any{
			queryParam("ts_start", false, strSchema(), "Lower bound, YYYY-MM-DD HH:mm:ss UTC (default now − 20 days)."),
			queryParam("limit", false, intSchema(), "Row limit (default 100)."),
		},
		envelope: envelope(map[string]any{"jobs_filtered": rowsRef}, "jobs_filtered"),
		errors:   map[int]string{400: "api_key is required!", 401: "Unauthorized access"},
	},
	"/integration/job_data_integration/:id_enterprise": {
		summary:  "Montebello job data integration over the last N days (frozen back4 contract).",
		security: secExtQuery,
		params: []any{
			queryParam("days_interval", true, intSchema(), "Days back, 1–41."),
			queryParam("site", false, strSchema(), "Optional site filter (upper-cased)."),
		},
		envelope: envelope(map[string]any{"data_integration": rowsRef}, "data_integration"),
		errors: map[int]string{400: "id is required! (missing/unknown api_key) | days interval must be between 1 and 41",
			422: "Invalid id (api_key's enterprise ≠ path id, or not the bound owner)"},
	},
	"/integration/get-shift-validation/:id_enterprise": {
		summary:  "Montebello shift validation (frozen back4 contract; every failure is a 500 with a message).",
		security: secExtQuery,
		params: []any{
			queryParam("days_interval", true, intSchema(), "Days back, 1–41."),
			queryParam("site", false, strSchema(), "Optional site suffix used to resolve the equipment topic."),
		},
		envelope: envelope(map[string]any{"shift_data": rowsRef}, "shift_data"),
		errors: map[int]string{500: "Not authorized! | Site does not exist! | Enterprise topic not found! | " +
			"Days interval must be between 1 and 41"},
	},
	"/integration/job_report/:id_enterprise": {
		summary:  "Incoplast job report (press counts) for the given equipment (frozen back4 contract).",
		security: secExtQuery,
		params: []any{queryParam("id_equipment", true, strSchema(),
			`Equipment id list: "1,2", "[1,2]" or "{1,2}".`)},
		envelope: envelope(map[string]any{"job_report": rowsRef}, "job_report"),
		errors: map[int]string{400: "id_enterprise is required! (missing/unknown api_key) | id_equipment is required!",
			422: "Invalid id (api_key's enterprise ≠ path id, or not the bound owner)"},
	},
}

// ── Small schema/parameter builders ──────────────────────────────────────────

func strSchema() map[string]any { return map[string]any{"type": "string"} }
func intSchema() map[string]any { return map[string]any{"type": "integer"} }
func dateTimeSchema() map[string]any {
	return map[string]any{"type": "string", "format": "date-time"}
}

func queryParam(name string, required bool, schema map[string]any, desc string) map[string]any {
	return map[string]any{"name": name, "in": "query", "required": required, "schema": schema, "description": desc}
}

func jsonContent(schema any) map[string]any {
	return map[string]any{"application/json": map[string]any{"schema": schema}}
}

func jsonResp(desc string, schema any) map[string]any {
	return map[string]any{"description": desc, "content": jsonContent(schema)}
}

// errResp is an http.Error response: text/plain carrying a JSON-looking body.
func errResp(desc string) map[string]any {
	return map[string]any{"description": desc, "content": map[string]any{
		"text/plain": map[string]any{"schema": map[string]any{"$ref": "#/components/schemas/ErrorText"}}}}
}

// tenantSecurity is what the auth middleware accepts (auth.go): X-Api-Key OR a
// Cognito Bearer. X-Api-Key wins when both are sent.
func tenantSecurity() []any {
	return []any{map[string]any{secAPIKey: []string{}}, map[string]any{secBearer: []string{}}}
}

// tenantOp stamps the security + 401 every middleware-guarded operation shares.
func tenantOp(tag, summary, desc string, params []any, body any, responses map[string]any) map[string]any {
	responses["401"] = map[string]any{"$ref": "#/components/responses/Unauthorized"}
	op := map[string]any{"tags": []string{tag}, "summary": summary, "security": tenantSecurity(), "responses": responses}
	if desc != "" {
		op["description"] = desc
	}
	if len(params) > 0 {
		op["parameters"] = params
	}
	if body != nil {
		op["requestBody"] = body
	}
	return op
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
		summary, ok := endpointSummaries[ep.path]
		if !ok {
			return nil, fmt.Errorf("endpoint %s has no summary in endpointSummaries", ep.path)
		}
		params, err := endpointArgParams(ep)
		if err != nil {
			return nil, err
		}
		resp := map[string]any{
			"200": jsonResp("Rows as objects; columns are the backing SQL object's.", rowsRef),
			"500": errResp("Query failed."),
		}
		if len(params) > 0 {
			resp["400"] = errResp("Missing or invalid query parameter.")
		}
		tag, desc := "operator-v1", "Tenant-scoped: the server binds the caller's tenant as $1; the client never names it."
		if strings.HasPrefix(ep.path, "/v2/") {
			tag = "operator-v2"
		}
		if ep.class == routeGlobalRef {
			tag, desc = "reference", "Global reference data: authenticated, but not tenant-filtered."
		}
		add(ep.path, "get", tenantOp(tag, summary, desc, params, nil, resp))
	}

	// 2) The composable query API (query.go / datasets.go).
	add("/v1/catalog", "get", tenantOp("query", "Query catalog: composer metrics/dimensions/grains and every named dataset.",
		"Tenant-independent schema metadata; authenticated.", nil, nil, map[string]any{
			"200": jsonResp("Catalog.", map[string]any{"type": "object", "properties": map[string]any{
				"metrics":    map[string]any{"type": "array", "items": strSchema()},
				"dimensions": map[string]any{"type": "array", "items": strSchema()},
				"grains":     map[string]any{"type": "object", "additionalProperties": strSchema(), "description": "grain → max window"},
				"row_limit":  intSchema(),
				"datasets": map[string]any{"type": "object", "description": "dataset name → {group, description, windowed, filters, max_window?, requires_user_context?}",
					"additionalProperties": map[string]any{"type": "object"}},
			}}),
		}))
	add("/v1/query", "post", tenantOp("query", "Run a named dataset or a metric × dimension composition.",
		"Two body shapes share the route: a body with `dataset` runs the named-dataset registry (cache-aside, "+
			"coverage headers); otherwise the metric×dimension composer. Per-dataset filters are listed by GET /v1/catalog.",
		nil,
		map[string]any{"required": true, "content": jsonContent(map[string]any{"oneOf": []any{
			map[string]any{"$ref": "#/components/schemas/DatasetQuery"},
			map[string]any{"$ref": "#/components/schemas/ComposerQuery"},
		}})},
		map[string]any{
			"200": map[string]any{"description": "Rows as objects.", "content": jsonContent(rowsRef),
				"headers": map[string]any{
					"X-Data-Hot-Floor": map[string]any{"description": "Dataset path only: oldest timestamp the dataset still holds (RFC3339).", "schema": strSchema()},
					"X-Data-Truncated": map[string]any{"description": "Dataset path only: \"true\" when the window starts before the hot floor.", "schema": strSchema()},
					"Warning":          map[string]any{"description": "Dataset path only: 299 warning accompanying X-Data-Truncated.", "schema": strSchema()},
				}},
			"400": errResp("Bad body, unknown dataset/metric/dimension/grain, or window outside budget."),
			"403": errResp("Per-user-role dataset called without a user (X-Api-Key path)."),
			"422": errResp("Composer window starts before the cagg's retention floor (use /v1/historian/*)."),
			"500": errResp("Query failed."),
		}))
	userScreen := []any{
		queryParam("user", true, strSchema(), "User id (selects a row within the caller's tenant)."),
		queryParam("screen", true, strSchema(), "Screen key."),
	}
	add("/v1/screen-config", "get", tenantOp("query", "Read a saved per-user screen layout.", "", userScreen, nil, map[string]any{
		"200": jsonResp("The stored config JSON, or {} when none.", map[string]any{"type": "object"}),
		"400": errResp("user and screen are required."),
	}))
	add("/v1/screen-config", "put", tenantOp("query", "Save a per-user screen layout.", "", userScreen,
		map[string]any{"required": true, "content": jsonContent(map[string]any{"description": "Any valid JSON, ≤ 64 KB."})},
		map[string]any{
			"200": jsonResp("Stored.", envelope(map[string]any{"ok": map[string]any{"type": "boolean"}}, "ok")),
			"400": errResp("user/screen missing, or config not valid JSON ≤ 64 KB."),
			"500": errResp("Store failed."),
		}))
	add("/v1/dashboard-config", "get", tenantOp("query", "Resolve a dashboard config (baseline ⊕ per-user override).", "",
		[]any{
			queryParam("dashboard_id", true, strSchema(), "Dashboard id."),
			queryParam("user", false, strSchema(), "Optional user id; absent ⇒ baseline only."),
		}, nil, map[string]any{
			"200": jsonResp("Resolution envelope.", map[string]any{"type": "object", "required": []string{"status"}, "properties": map[string]any{
				"status":  map[string]any{"type": "string", "enum": []string{"ok", "not_found", "invalid"}},
				"config":  map[string]any{"type": "object"},
				"version": intSchema(),
				"issues": map[string]any{"type": "array", "items": envelope(map[string]any{
					"path": strSchema(), "message": strSchema()}, "path", "message")},
			}}),
			"400": errResp("dashboard_id is required."),
			"500": errResp("Query failed."),
		}))

	// 3) The historian gateway reach (historian.go).
	for _, h := range []struct{ path, summary, cols string }{
		{"/v1/historian/production-series", "Daily gross/net production per equipment, hot + cold archive.",
			"day, id_equipment, gross_production, net_production"},
		{"/v1/historian/downtime-series", "Daily downtime per equipment split by planned_downtime, hot + cold archive.",
			"day, id_equipment, planned_downtime, event_count, downtime_seconds"},
	} {
		add(h.path, "post", tenantOp("historian", h.summary, "Window ≤ ~5 years. 503 when the historian gateway is not configured.", nil,
			map[string]any{"required": true, "content": jsonContent(map[string]any{"$ref": "#/components/schemas/HistorianWindow"})},
			map[string]any{
				"200": jsonResp("Rows: "+h.cols+".", rowsRef),
				"400": errResp("Bad body, from ≥ to, or window over budget."),
				"405": errResp("POST only."),
				"500": errResp("Historian query failed."),
				"503": errResp("Historian gateway not configured."),
			}))
	}

	// 4) The service-to-service resolver (internal.go).
	add("/internal/resolve-device", "get", map[string]any{
		"tags":     []string{"internal"},
		"summary":  "Resolve an opaque device_key to its active id_equipment (edge-transformer birth binding).",
		"security": []any{map[string]any{secInternalKey: []string{}}},
		"parameters": []any{
			queryParam("device_key", true, map[string]any{"type": "string", "pattern": deviceKeyRe.String()}, "Opaque device key."),
			queryParam("enterprise", false, intSchema(), "Optional positive id_enterprise filter."),
		},
		"responses": map[string]any{
			"200": jsonResp("The binding.", envelope(map[string]any{"id_equipment": intSchema(), "id_enterprise": intSchema()},
				"id_equipment", "id_enterprise")),
			"400": errResp("device_key missing or not a dk_ key, or enterprise not a positive integer."),
			"401": errResp("Missing/mismatched X-Internal-Key, or INTERNAL_API_KEY unset (endpoint inert)."),
			"404": errResp("No active binding for the key."),
			"405": errResp("GET only."),
			"500": errResp("Query failed."),
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
				params = append(params, map[string]any{"name": name, "in": "path", "required": true, "schema": intSchema(),
					"description": "Must equal the api_key's own enterprise (and the shim's bound owner)."})
			}
		}
		params = append(params, doc.params...)
		resp := map[string]any{"200": jsonResp("Frozen envelope; row columns and order are the backing object's.", doc.envelope)}
		for code, body := range doc.errors {
			resp[fmt.Sprint(code)] = map[string]any{"description": body, "content": map[string]any{
				"text/html": map[string]any{"schema": strSchema()}}}
		}
		add(muxPattern(sh.path), "get", map[string]any{
			"tags":        []string{"external"},
			"summary":     doc.summary,
			"description": fmt.Sprintf("Anti-corruption shim (ADR-0031), consumer %q. Self-authenticates; the key must resolve to the shim's bound owner (%s). Error bodies are back4's exact text/html strings.", sh.consumer, sh.ownerEnv),
			"security":    []any{map[string]any{doc.security: []string{}}},
			"parameters":  params,
			"responses":   resp,
		})
	}

	return map[string]any{
		"openapi": "3.1.0",
		"info": map[string]any{
			"title":   "read-api (refdata-api)",
			"version": "1.0.0",
			"description": "Packiot read plane: the Hasura-replacement operator reads, the composable query API, " +
				"the historian reach, and frozen foreign-contract shims. Tenant routes derive the tenant from the " +
				"credential (X-Api-Key or Cognito Bearer) and never accept it from the client. Operator super-admin " +
				"cross-tenant escalation (dark unless OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED): send " +
				"`x-operator-superadmin-token: <Cognito ID token>` plus `?idEnterprise=<target>` alongside the normal " +
				"credential; any failed check silently keeps the home tenant.",
		},
		"servers": openAPIServers,
		"tags": []any{
			map[string]any{"name": "operator-v1", "description": "Hasura-replacement operator reads (topic-keyed)."},
			map[string]any{"name": "operator-v2", "description": "Operator reads keyed by id_equipment (ADR-0061 P3)."},
			map[string]any{"name": "reference", "description": "Global reference data."},
			map[string]any{"name": "query", "description": "Composable query API, datasets, layouts (ADR-0015)."},
			map[string]any{"name": "historian", "description": "Hot + cold archive reads via the historian gateway."},
			map[string]any{"name": "internal", "description": "Service-to-service endpoints."},
			map[string]any{"name": "external", "description": "Frozen back4 contracts for ERP/BI integrations (ADR-0031)."},
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
				"Unauthorized": errResp("Missing or invalid credentials."),
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
		filterProps[d] = map[string]any{"type": "array", "items": intSchema()}
	}
	return map[string]any{
		"Rows": map[string]any{"type": "array", "items": map[string]any{"type": "object", "additionalProperties": true},
			"description": "Result rows as JSON objects; the columns are whatever the backing view/function returns."},
		"ErrorText": map[string]any{"type": "string", "examples": []string{`{"error":"query failed"}`},
			"description": "http.Error body: JSON-formatted text served as text/plain."},
		"DatasetQuery": map[string]any{"type": "object", "required": []string{"dataset"}, "properties": map[string]any{
			"dataset": map[string]any{"type": "string", "enum": sortedKeys(datasets)},
			"window": map[string]any{"type": "object", "description": "Required for windowed datasets, rejected otherwise. Bounds accept " +
				"YYYY-MM-DD, YYYY-MM-DD HH:mm, YYYY-MM-DD HH:mm:ss or RFC3339.",
				"required": []string{"from", "to"}, "properties": map[string]any{"from": strSchema(), "to": strSchema()}},
			"filters": map[string]any{"type": "object", "additionalProperties": true,
				"description": "Per-dataset filters (see GET /v1/catalog → datasets[name].filters)."},
		}},
		"ComposerQuery": map[string]any{"type": "object", "required": []string{"metrics", "grain", "from", "to"}, "properties": map[string]any{
			"metrics":    map[string]any{"type": "array", "minItems": 1, "items": map[string]any{"type": "string", "enum": sortedKeys(metrics)}},
			"dimensions": map[string]any{"type": "array", "items": map[string]any{"type": "string", "enum": dims}},
			"grain":      map[string]any{"type": "string", "enum": sortedKeys(grains)},
			"from":       dateTimeSchema(),
			"to":         dateTimeSchema(),
			"filters":    map[string]any{"type": "object", "properties": filterProps, "additionalProperties": false},
		}},
		"HistorianWindow": map[string]any{"type": "object", "required": []string{"from", "to"}, "properties": map[string]any{
			"from":      dateTimeSchema(),
			"to":        dateTimeSchema(),
			"equipment": map[string]any{"type": "array", "items": intSchema(), "description": "Optional id_equipment filter; empty ⇒ all of the tenant's."},
		}},
	}
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
		once.Do(func() {
			var spec map[string]any
			if spec, err = buildOpenAPISpec(); err == nil {
				body, err = json.Marshal(spec)
			}
		})
		if err != nil {
			http.Error(w, `{"error":"openapi build failed"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}
}
