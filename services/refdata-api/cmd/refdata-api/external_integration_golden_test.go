package main

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// external_integration_golden_test.go — ADR-0031 §3c golden gate for the three
// back4 /integration/* Family-A shims (job_data_integration, job_report,
// get-shift-validation) PLUS the framework wildcard-auth extension (auth.go's
// muxPattern + exemptMatch) that these path-param routes required.
//
// Same discipline as the NEOPAC / Montebello-Incoplast suites: drive the REAL
// registered shim runner with a scripted (no-DB) row source and assert the
// response is BYTE-IDENTICAL to the frozen back4 shape, plus each shim's distinct
// auth ladder + error shape (job_report/job_data_integration's 400/422;
// get-shift-validation's 500-for-all membrane) and the owner-binding isolation.
//
// SCOPE (§3c shadow-diff now CLOSED): fixtures include the prod-typed numeric +
// bigint columns. Verified SELECT-only against prod: job_report's presscount is
// sum(gross_production_incr) → DOUBLE PRECISION, so it stays a JSON NUMBER on both
// drivers — job_report is numeric-CLEAN (pinned as a number below). get_data_sync
// _enterprsie_06b (job_data_integration) projects bigint + numeric(10,2) columns →
// node-pg strings. get-shift-validation's index1/shift_hrs are TEXT (always
// strings), id_order is BIGINT → a string; its jsonb columns are a SEPARATE
// (jsonb key-order) shadow-diff flagged in the report, not this numeric one.

// intReq builds a GET request with the :id_enterprise path value set (as the mux
// would). pathID is a string so a test can pass a MISMATCHED id to drive the 422.
func intReq(target, pathID string) *http.Request {
	req := httptest.NewRequest("GET", target, nil)
	req.SetPathValue("id_enterprise", pathID)
	return req
}

// ── Framework: the wildcard-auth extension (the blocker #528 flagged) ─────────

// TestMuxPatternTranslation locks the Express→Go pattern translation and that
// concrete paths (the NEOPAC/Montebello/Incoplast /ext/* mounts + infra) are
// passed through byte-unchanged — the "additive" guarantee.
func TestMuxPatternTranslation(t *testing.T) {
	cases := map[string]string{
		"/integration/job_report/:id_enterprise":           "/integration/job_report/{id_enterprise}",
		"/integration/get-shift-validation/:id_enterprise": "/integration/get-shift-validation/{id_enterprise}",
		"/ext/neopac/sap-report":                           "/ext/neopac/sap-report", // concrete unchanged
		"/healthz":                                         "/healthz",
	}
	for in, want := range cases {
		if got := muxPattern(in); got != want {
			t.Errorf("muxPattern(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestPathMatchesSemantics pins the segment matcher against Go 1.22 {name}
// semantics: one non-empty segment bound, equal segment counts, literals exact.
func TestPathMatchesSemantics(t *testing.T) {
	pat := "/integration/job_report/:id_enterprise"
	match := []string{"/integration/job_report/123", "/integration/job_report/4"}
	noMatch := []string{
		"/integration/job_report/",    // empty wildcard segment
		"/integration/job_report/1/2", // extra segment
		"/integration/job_report",     // missing segment
		"/integration/job_data/123",   // literal differs
		"/ext/neopac/sap-report",      // unrelated
	}
	for _, p := range match {
		if !pathMatches(pat, p) {
			t.Errorf("pathMatches(%q, %q) = false, want true", pat, p)
		}
	}
	for _, p := range noMatch {
		if pathMatches(pat, p) {
			t.Errorf("pathMatches(%q, %q) = true, want false", pat, p)
		}
	}
}

// TestExemptMatchWildcardVsConcrete is the crux of the framework fix: a CONCRETE
// /integration/job_report/123 must be recognized as auth-exempt (so it reaches the
// shim to reproduce back4's own status shapes), while the exact-match behavior for
// infra + the /ext/* shims is unchanged and /v1 reads stay NON-exempt.
func TestExemptMatchWildcardVsConcrete(t *testing.T) {
	exempt := authExemptSet()
	yes := []string{
		"/integration/job_report/123",         // wildcard shim, concrete id
		"/integration/job_data_integration/6", // wildcard shim, concrete id
		"/integration/get-shift-validation/6", // wildcard shim, concrete id
		"/ext/neopac/sap-report",              // concrete shim (byte-unchanged)
		"/healthz", "/metrics",                // infra
	}
	no := []string{
		"/v1/operator-po-list",     // a tenant read — must resolve the key
		"/v1/query",                //   "
		"/integration/job_report/", // no id → not a shim match
		"/integration/unknown/123", // no such shim
	}
	for _, p := range yes {
		if !exemptMatch(exempt, p) {
			t.Errorf("exemptMatch(%q) = false, want true (foreign contract would break)", p)
		}
	}
	for _, p := range no {
		if exemptMatch(exempt, p) {
			t.Errorf("exemptMatch(%q) = true, want false (a read must not be auth-exempt)", p)
		}
	}
}

// TestIntegrationShimEndToEndThroughMiddleware is the strongest wiring proof: a
// CONCRETE /integration/job_report/<owner> routed through the SAME stack as prod —
// authMiddleware(exemptSet) in front of a real ServeMux mounting the shim at
// muxPattern — (a) is let through by the exempt match, (b) is routed by the {id_
// enterprise} wildcard with r.PathValue populated, and (c) reaches the shim, which
// reproduces the foreign contract (200 happy path AND the shim's OWN 400 when
// id_equipment is missing — proving the request was NEVER intercepted by the
// JSON-401 middleware). Before the extension, both would be a JSON 401.
func TestIntegrationShimEndToEndThroughMiddleware(t *testing.T) {
	sh := shimByPath(t, "/integration/job_report/:id_enterprise")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		// presscount = sum(gross_production_incr) → DOUBLE PRECISION → a JSON number
		// (float8 matches node-pg + pgx; the numeric fix does NOT touch it). Same row
		// as TestJobReportGoldenShape so both share the incoplast/job_report golden.
		return externalRows{
			cols: []string{"id_equipment", "cd_shift", "ts_value_production", "id_order", "presscount", "ts_start", "packml_topic"},
			rows: [][]any{{42, "T1", tsUTC(6, 0, 0), "OP-901", 4200.5, tsUTC(6, 0, 0), "spBv1.0/inco/DDATA/EX2"}},
		}, nil
	}}
	mux := http.NewServeMux()
	mux.HandleFunc(muxPattern(sh.path), makeExternalHandler(sh, reader, mbKeys(), incoplastOwner, discardLogger()))
	authed := authMiddleware(mbKeys(), authExemptSet(), nil, mux) // nil bearer: doesn't matter, route is exempt

	owner := strconv.Itoa(incoplastOwner)

	// (a) happy path — routed, PathValue bound, shim runs, byte-identical golden.
	rr := httptest.NewRecorder()
	authed.ServeHTTP(rr, httptest.NewRequest("GET",
		"/integration/job_report/"+owner+"?api_key="+incoplastKey+"&id_equipment=42", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("e2e happy: code = %d, want 200 (routing/exemption/PathValue broken)", rr.Code)
	}
	compareGolden(t, "incoplast", "job_report", rr.Body.String())

	// (b) missing id_equipment → the SHIM's own 400 (text/html), NOT the JSON-401
	// middleware — proof the exempt match let the request through to the shim.
	rr2 := httptest.NewRecorder()
	authed.ServeHTTP(rr2, httptest.NewRequest("GET",
		"/integration/job_report/"+owner+"?api_key="+incoplastKey, nil))
	if rr2.Code != http.StatusBadRequest || rr2.Body.String() != "id_equipment is required!" {
		t.Errorf("e2e no-id_equipment: got (%d,%q); want (400,\"id_equipment is required!\") — middleware must not intercept",
			rr2.Code, rr2.Body.String())
	}
	if ct := rr2.Header().Get("Content-Type"); ct != "text/html; charset=utf-8" {
		t.Errorf("e2e no-id_equipment CT = %q, want text/html; charset=utf-8 (foreign shape, not JSON-401)", ct)
	}
}

// ── Montebello: job_data_integration → {data_integration} ─────────────────────

func TestJobDataIntegrationGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/integration/job_data_integration/:id_enterprise")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		// ent-06-frozen function: NO id_enterprise arg — the fence is the owner
		// binding. $1 = days_interval, $2 = site (when present).
		if !strings.Contains(sql, "get_data_sync_enterprsie_06b($1)") {
			t.Errorf("expected the frozen ent-06 function, got %s", sql)
		}
		// get_data_sync_enterprsie_06b projects bigint (job, presscnt) → node-pg
		// strings, and numeric(10,2) (totalavailablehrsinmin, setuphoursinmin→"0.00")
		// → strings with scale. All delivered as Go strings by the reader.
		return externalRows{
			cols: []string{"site", "nm_equipment", "job", "totalavailablehrsinmin", "setuphoursinmin", "presscnt", "ts_start", "packml_topic"},
			rows: [][]any{{"MTB-SITE", "Extrusora 1 <A&B>", "8801", "480.00", "0.00", "12345", tsUTC(6, 0, 0), "spBv1.0/mtb/DDATA/L01"}},
		}, nil
	}}
	req := intReq("/integration/job_data_integration/"+strconv.Itoa(montebelloOwner)+"?api_key="+montebelloKey+"&days_interval=7&site=mtb-site", strconv.Itoa(montebelloOwner))
	status, ct, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)
	if status != http.StatusOK || ct != "application/json; charset=utf-8" {
		t.Errorf("status/ct = %d/%q, want 200/application/json; charset=utf-8", status, ct)
	}
	compareGolden(t, "montebello", "job_data_integration", body)
}

// TestJobDataIntegrationDaysInterval pins the post-auth 400 window (1..41) and the
// site-filter binding ($1=days, $2=UPPER(site)).
func TestJobDataIntegrationDaysInterval(t *testing.T) {
	sh := shimByPath(t, "/integration/job_data_integration/:id_enterprise")
	var gotSQL string
	var gotArgs []any
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		gotSQL, gotArgs = sql, args
		return externalRows{cols: []string{"site"}, rows: nil}, nil
	}}
	owner := strconv.Itoa(montebelloOwner)
	bad := []string{"", "0", "-3", "42", "100"}
	for _, di := range bad {
		req := intReq("/integration/job_data_integration/"+owner+"?api_key="+montebelloKey+"&days_interval="+di, owner)
		status, ct, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)
		if status != http.StatusBadRequest || body != "days interval must be between 1 and 41" || ct != "text/html; charset=utf-8" {
			t.Errorf("days_interval=%q: got (%d,%q,%q); want (400,text/html; charset=utf-8,\"days interval must be between 1 and 41\")", di, status, ct, body)
		}
	}
	// valid → reads with site filter bound.
	req := intReq("/integration/job_data_integration/"+owner+"?api_key="+montebelloKey+"&days_interval=10&site=abc", owner)
	if status, _, _ := serveShim(sh, reader, mbKeys(), montebelloOwner, req); status != http.StatusOK {
		t.Fatalf("valid days_interval status = %d, want 200", status)
	}
	if !strings.Contains(gotSQL, "where site = UPPER($2)") {
		t.Errorf("site SQL wrong: %s", gotSQL)
	}
	if len(gotArgs) != 2 || gotArgs[0] != 10 || gotArgs[1] != "abc" {
		t.Errorf("args = %v, want [10 abc]", gotArgs)
	}
}

// ── The shared /integration/:id_enterprise auth ladder (400 + 422) ────────────

// TestIntegrationEnterpriseAuthMatrix pins the back4 ladder for BOTH
// job_data_integration ("id is required!") and job_report ("id_enterprise is
// required!"): unknown/missing key → 400 <missingBody>; valid key whose enterprise
// ≠ the path id (or a non-owner key) → 422 "Invalid id"; and no read on rejection.
func TestIntegrationEnterpriseAuthMatrix(t *testing.T) {
	type shimCase struct {
		path, missingBody, extraQuery string
		owner                         int
		ownerKey                      string
	}
	shims := []shimCase{
		{"/integration/job_data_integration/:id_enterprise", "id is required!", "&days_interval=7", montebelloOwner, montebelloKey},
		{"/integration/job_report/:id_enterprise", "id_enterprise is required!", "&id_equipment=42", incoplastOwner, incoplastKey},
	}
	for _, sc := range shims {
		t.Run(sc.path, func(t *testing.T) {
			sh := shimByPath(t, sc.path)
			reader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
				return externalRows{cols: []string{"x"}, rows: nil}, nil
			}}
			ownerStr := strconv.Itoa(sc.owner)
			cases := []struct {
				name           string
				apiKey, pathID string
				wantCode       int
				wantBody       string
				wantRead       bool
			}{
				{"missing key → 400", "", ownerStr, 400, sc.missingBody, false},
				{"unknown key → 400", "no-such", ownerStr, 400, sc.missingBody, false},
				{"path id ≠ key enterprise → 422", sc.ownerKey, "999", 422, "Invalid id", false},
				{"non-owner valid key → 422", strangerKey, strconv.Itoa(strangerOwner), 422, "Invalid id", false},
				{"owner key + owner id → 200", sc.ownerKey, ownerStr, 200, "", true},
			}
			for _, c := range cases {
				t.Run(c.name, func(t *testing.T) {
					reader.called = 0
					target := sc.path[:strings.Index(sc.path, "/:")] + "/" + c.pathID + "?api_key=" + c.apiKey + sc.extraQuery
					req := intReq(target, c.pathID)
					status, ct, body := serveShim(sh, reader, mbKeys(), sc.owner, req)
					if c.wantCode != 200 {
						if status != c.wantCode || body != c.wantBody || ct != "text/html; charset=utf-8" {
							t.Errorf("got (%d,%q,%q); want (%d,text/html,%q)", status, ct, body, c.wantCode, c.wantBody)
						}
					} else if status != 200 {
						t.Errorf("owner happy path status = %d, want 200", status)
					}
					if (reader.called > 0) != c.wantRead {
						t.Errorf("reader called=%d, wantRead=%v — a rejected caller reads nothing", reader.called, c.wantRead)
					}
				})
			}
		})
	}
}

// ── Incoplast: job_report → {job_report} ──────────────────────────────────────

func TestJobReportGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/integration/job_report/:id_enterprise")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		// Fenced by $1 = cid; id list bound as $2 int[] (back4's IN(...) → ANY).
		if len(args) < 2 || args[0] != incoplastOwner {
			t.Errorf("job_report must bind $1 = cid (%d); got %v", incoplastOwner, args)
		}
		if ids, ok := args[1].([]int); !ok || !reflect.DeepEqual(ids, []int{42, 43}) {
			t.Errorf("id_equipment must bind $2 = []int{42,43}; got %#v", args[1])
		}
		// presscount = sum(gross_production_incr) → DOUBLE PRECISION → a JSON number
		// (job_report is numeric-CLEAN). Identical row to the e2e test above.
		return externalRows{
			cols: []string{"id_equipment", "cd_shift", "ts_value_production", "id_order", "presscount", "ts_start", "packml_topic"},
			rows: [][]any{{42, "T1", tsUTC(6, 0, 0), "OP-901", 4200.5, tsUTC(6, 0, 0), "spBv1.0/inco/DDATA/EX2"}},
		}, nil
	}}
	// id_equipment as a bracketed list to exercise the strip+split+int parse.
	req := intReq("/integration/job_report/"+strconv.Itoa(incoplastOwner)+"?api_key="+incoplastKey+"&id_equipment={42,43}", strconv.Itoa(incoplastOwner))
	status, ct, body := serveShim(sh, reader, mbKeys(), incoplastOwner, req)
	if status != http.StatusOK || ct != "application/json; charset=utf-8" {
		t.Errorf("status/ct = %d/%q", status, ct)
	}
	compareGolden(t, "incoplast", "job_report", body)
}

func TestJobReportIdEquipmentRequired(t *testing.T) {
	sh := shimByPath(t, "/integration/job_report/:id_enterprise")
	reader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
		t.Fatal("reader ran without id_equipment — must 400 before reading")
		return externalRows{}, nil
	}}
	owner := strconv.Itoa(incoplastOwner)
	for _, ie := range []string{"", "undefined"} {
		q := "?api_key=" + incoplastKey
		if ie != "" {
			q += "&id_equipment=" + ie
		}
		req := intReq("/integration/job_report/"+owner+q, owner)
		status, ct, body := serveShim(sh, reader, mbKeys(), incoplastOwner, req)
		if status != http.StatusBadRequest || body != "id_equipment is required!" || ct != "text/html; charset=utf-8" {
			t.Errorf("id_equipment=%q: got (%d,%q,%q); want (400,text/html,\"id_equipment is required!\")", ie, status, ct, body)
		}
	}
}

func TestParseIDList(t *testing.T) {
	cases := map[string][]int{
		"1,2,3":   {1, 2, 3},
		"{42,43}": {42, 43},
		"[7]":     {7},
		"(5, 6)":  {5, 6},
	}
	for in, want := range cases {
		if got := parseIDList(in); !reflect.DeepEqual(got, want) {
			t.Errorf("parseIDList(%q) = %v, want %v", in, got, want)
		}
	}
}

// ── Montebello: get-shift-validation → {shift_data} (distinct 500 membrane) ────

// TestShiftValidationGoldenShape pins the frozen `{shift_data}` envelope, the
// dayjs `YYYY-MM-DD` adapter on ts_value_production, AND the multi-DAO resolution:
// no-site → getEnterpriseTopic → topic = leading '/'-segment → findByTopic bound
// with LIKE '%topic%'.
func TestShiftValidationGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/integration/get-shift-validation/:id_enterprise")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		switch {
		case strings.Contains(sql, "equipment_validation_shift"):
			// topic = "spBv1.0" (split '/'[0]) → LIKE wrapped to '%spBv1.0%'.
			if len(args) < 2 || args[1] != "%spBv1.0%" {
				t.Errorf("findByTopic must bind $2 = '%%spBv1.0%%'; got %v", args)
			}
			// index1 is TEXT → always a string ("7"); id_site is int4 → number;
			// id_order is BIGINT → node-pg string. txt_validation_notes is JSONB —
			// kept as a scalar-string stand-in; jsonb key-ORDER parity is a SEPARATE
			// shadow-diff flagged in the report, not this numeric one.
			return externalRows{
				cols: []string{"index1", "packml_topic", "id_site", "ts_value_production", "cd_shift", "id_order", "txt_validation_notes", "to_delete"},
				rows: [][]any{{"7", "spBv1.0/mtb/DDATA/L01", 14, tsUTC(6, 0, 0), "T1", "5000000001", "ok <A&B>", false}},
			}, nil
		case strings.Contains(sql, "LIMIT 1"): // getEnterpriseTopic, fenced by $1 = cid
			if len(args) < 1 || args[0] != montebelloOwner {
				t.Errorf("getEnterpriseTopic must fence $1 = cid; got %v", args)
			}
			return externalRows{cols: []string{"packml_topic"}, rows: [][]any{{"spBv1.0/mtb/DDATA/L01"}}}, nil
		}
		t.Fatalf("unexpected SQL: %s", sql)
		return externalRows{}, nil
	}}
	owner := strconv.Itoa(montebelloOwner)
	req := intReq("/integration/get-shift-validation/"+owner+"?api_key="+montebelloKey+"&days_interval=7", owner)
	status, ct, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)
	if status != http.StatusOK || ct != "application/json; charset=utf-8" {
		t.Errorf("status/ct = %d/%q", status, ct)
	}
	compareGolden(t, "montebello", "get-shift-validation", body)
}

// TestShiftValidation500Membrane is the DISTINCT-MEMBRANE gate: EVERY error is a
// 500-with-message (text/html), never the 400/401/422 matrix — auth failure,
// site-not-found, and days-out-of-range all 500 with their pinned bodies.
func TestShiftValidation500Membrane(t *testing.T) {
	sh := shimByPath(t, "/integration/get-shift-validation/:id_enterprise")
	owner := strconv.Itoa(montebelloOwner)

	// (1) auth failure (wrong tenant / unknown key / mismatched path id) → 500
	// "Not authorized!" and NO read.
	authReader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
		t.Fatal("reader ran on an auth failure — the 500 membrane must fence before any read")
		return externalRows{}, nil
	}}
	for _, c := range []struct{ name, apiKey, pathID string }{
		{"unknown key", "no-such", owner},
		{"wrong tenant", incoplastKey, owner},
		{"path id ≠ owner", montebelloKey, "999"},
	} {
		req := intReq("/integration/get-shift-validation/"+c.pathID+"?api_key="+c.apiKey+"&days_interval=7", c.pathID)
		status, ct, body := serveShim(sh, authReader, mbKeys(), montebelloOwner, req)
		if status != http.StatusInternalServerError || body != "Not authorized!" || ct != "text/html; charset=utf-8" {
			t.Errorf("%s: got (%d,%q,%q); want (500,text/html,\"Not authorized!\")", c.name, status, ct, body)
		}
	}

	// (2) site given but not found → 500 "Site does not exist!".
	siteReader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		return externalRows{cols: []string{"packml_topic"}, rows: nil}, nil // empty getSiteTopic
	}}
	req := intReq("/integration/get-shift-validation/"+owner+"?api_key="+montebelloKey+"&days_interval=7&site=nope", owner)
	if status, ct, body := serveShim(sh, siteReader, mbKeys(), montebelloOwner, req); status != 500 || body != "Site does not exist!" || ct != "text/html; charset=utf-8" {
		t.Errorf("site-not-found: got (%d,%q,%q); want (500,text/html,\"Site does not exist!\")", status, ct, body)
	}

	// (3) days_interval out of range (checked AFTER topic resolution) → 500
	// "Days interval must be between 1 and 41" (capital D — distinct body).
	daysReader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		if strings.Contains(sql, "equipment_validation_shift") {
			t.Fatal("findByTopic ran despite a bad days_interval — must 500 first")
		}
		return externalRows{cols: []string{"packml_topic"}, rows: [][]any{{"spBv1.0/x"}}}, nil
	}}
	for _, di := range []string{"0", "100"} {
		req := intReq("/integration/get-shift-validation/"+owner+"?api_key="+montebelloKey+"&days_interval="+di, owner)
		status, ct, body := serveShim(sh, daysReader, mbKeys(), montebelloOwner, req)
		if status != 500 || body != "Days interval must be between 1 and 41" || ct != "text/html; charset=utf-8" {
			t.Errorf("days=%q: got (%d,%q,%q); want (500,text/html,\"Days interval must be between 1 and 41\")", di, status, ct, body)
		}
	}
}

// TestDateOnlyFormat locks the dayjs adapter: bare calendar date, no time, no zone.
func TestDateOnlyFormat(t *testing.T) {
	if got := dateOnlyFormat(tsUTC(23, 59, 59)); got != "2026-07-18" {
		t.Errorf("dateOnlyFormat = %q, want 2026-07-18", got)
	}
}

// ── Drift gate: the frozen /integration/* backing objects are carried in ──────

func TestIntegrationBackingObjectsAreDriftGated(t *testing.T) {
	objs, err := extractContract()
	if err != nil {
		t.Fatalf("extractContract: %v", err)
	}
	type key struct{ kind, name string }
	want := map[key]bool{
		{"function", "get_data_sync_enterprsie_06b"}: false, // job_data_integration (argc 1)
		{"relation", "equipment_validation_shift"}:   false, // get-shift-validation
		{"relation", "equipment_runtime_shift"}:      false, // job_report
		{"relation", "agg_equipment_values_1min_t"}:  false, // job_report
	}
	for _, o := range objs {
		if o.Source != "external" {
			continue
		}
		k := key{o.Kind, o.Name}
		if _, tracked := want[k]; tracked {
			want[k] = true
			if o.Kind == "function" && o.Name == "get_data_sync_enterprsie_06b" && o.ArgC != 1 {
				t.Errorf("get_data_sync_enterprsie_06b argc = %d, want 1", o.ArgC)
			}
		}
	}
	for k, found := range want {
		if !found {
			t.Errorf("frozen external %s %q not in the drift-gate contract dump", k.kind, k.name)
		}
	}
}
