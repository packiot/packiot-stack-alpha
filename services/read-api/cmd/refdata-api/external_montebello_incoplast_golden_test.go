package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// external_montebello_incoplast_golden_test.go — ADR-0031 §3c golden gate for
// the Montebello (ent 6) + Incoplast (api_key) Family-A shims.
//
// Same discipline as external_golden_test.go (NEOPAC): drive the REAL registered
// shim runner with a scripted (no-DB) row source and assert the response is
// BYTE-IDENTICAL to the frozen back4 shape — envelope keys + ORDER, the RAW
// unparsed `page`, the moment `[Z]` timestamps (second precision, literal Z, no
// millis), pagination int types, no HTML-escaping, no trailing newline — plus
// the error matrix and the owner-binding isolation gate.
//
// SCOPE (§3c shadow-diff now CLOSED, same as NEOPAC): fixtures now include the
// prod-typed numeric + bigint columns. node-pg returns numeric/decimal + bigint
// (int8) as JSON STRINGS (scale preserved); the reader forces those OIDs to text
// and passes the raw Postgres text through, so a fixture value for such a column
// is the string node-pg delivers. Notable prod typings verified SELECT-only:
// pack_id (events) is BIGINT → a string, not the number a naive fixture assumed;
// duration (events) is int4 → a number; net/gross_production (inco jobs) are
// DOUBLE PRECISION → numbers (float8 matches both drivers, no fix). Each is
// pinned in its real form below. JSONB (custom_field) is ALSO now included: node-pg
// re-emits it as an OBJECT in jsonb's stored key order (reserialized by
// nodePgJSONText, proven byte-identical to a live node reference on real rows).

// This suite's own key map (independent of the NEOPAC suite's): the Montebello
// api_key resolves to ent 6, the Incoplast key to its enterprise, and a
// "stranger" key to a third tenant to prove the owner binding rejects it.
// (These stand in for QUERY_API_KEYS entries, not code literals.)
const (
	montebelloKey   = "montebello-sync-key"
	montebelloOwner = 6
	incoplastKey    = "incoplast-api-key"
	incoplastOwner  = 4
	strangerKey     = "stranger-key"
	strangerOwner   = 99
)

func mbKeys() map[string]int {
	return map[string]int{
		montebelloKey: montebelloOwner,
		incoplastKey:  incoplastOwner,
		strangerKey:   strangerOwner,
	}
}

// tsUTC is a helper for fixture timestamps (UTC, so the golden output is
// deterministic regardless of the test host's zone).
func tsUTC(h, m, s int) time.Time {
	return time.Date(2026, 7, 18, h, m, s, 0, time.UTC)
}

// ── Montebello data-sync — {page,results,data}, RAW page ─────────────────────

// TestMontebelloDataSyncGoldenShape pins the frozen `{page,results,data}`
// envelope: `page` echoed as the RAW query STRING "2" (back4 does NOT parseInt
// it, unlike NEOPAC sap-report-sync), results = row count, data in column order,
// a `<A&B>` column to prove no HTML-escape, and a default-ISO (.000Z) timestamp.
func TestMontebelloDataSyncGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/ext/montebello/data-sync")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		// uniqueid is bigint → node-pg string; totalavailablehrsinmin is
		// numeric(10,2) → "480.00"; dtimehrsplannedinmin a zero of the same → "0.00"
		// (the frozen v_piot_production_data_sync_cust6 numerics).
		return externalRows{
			cols: []string{"site", "nm_equipment", "uniqueid", "totalavailablehrsinmin", "dtimehrsplannedinmin", "ts_start", "packml_topic"},
			rows: [][]any{{"MTB-SITE", "Linha 3 <A&B>", "71662", "480.00", "0.00", tsUTC(6, 0, 0), "spBv1.0/mtb/DDATA/L01"}},
		}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/montebello/data-sync?site=mtb-site&page=2&limit=50", nil)
	req.Header.Set("x-api-key", montebelloKey)
	status, ct, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)

	if status != http.StatusOK {
		t.Errorf("status = %d, want 200", status)
	}
	if ct != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want application/json; charset=utf-8", ct)
	}
	compareGolden(t, "montebello", "data-sync", body)
}

// TestMontebelloDataSyncRawPageQuirk locks the two halves of the raw-page quirk:
// present ⇒ the STRING is echoed verbatim (even a non-numeric one); absent ⇒ the
// INT default 1. And the SQL binding: with `site`, filter is $1 and LIMIT/OFFSET
// are $2/$3; without `site`, LIMIT/OFFSET are $1/$2 (defaults limit=600).
func TestMontebelloDataSyncRawPageQuirk(t *testing.T) {
	sh := shimByPath(t, "/ext/montebello/data-sync")
	var gotSQL string
	var gotArgs []any
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		gotSQL, gotArgs = sql, args
		return externalRows{cols: []string{"site"}, rows: nil}, nil
	}}

	// (a) page present + non-numeric → echoed as the raw string; no site ⇒
	//     t244: serving.production_data_sync($1=cid) LIMIT $2 OFFSET $3, default
	//     limit 600, offset (1-1)*600 = 0 (page "x" parses to the default 1 for the
	//     offset math).
	req := httptest.NewRequest("GET", "/ext/montebello/data-sync?page=x", nil)
	req.Header.Set("x-api-key", montebelloKey)
	_, _, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)
	if want := `{"page":"x","results":0,"data":[]}`; body != want {
		t.Errorf("raw string page: body = %s, want %s", body, want)
	}
	if !strings.Contains(gotSQL, "serving.production_data_sync($1) limit $2 offset $3") {
		t.Errorf("no-site SQL should be `serving.production_data_sync($1) limit $2 offset $3`, got %s", gotSQL)
	}
	if len(gotArgs) != 3 || gotArgs[0] != montebelloOwner || gotArgs[1] != 600 || gotArgs[2] != 0 {
		t.Errorf("no-site args = %v, want [%d 600 0]", gotArgs, montebelloOwner)
	}

	// (b) page absent → the INT default 1 (not "1").
	req2 := httptest.NewRequest("GET", "/ext/montebello/data-sync", nil)
	req2.Header.Set("x-api-key", montebelloKey)
	_, _, body2 := serveShim(sh, reader, mbKeys(), montebelloOwner, req2)
	if want := `{"page":1,"results":0,"data":[]}`; body2 != want {
		t.Errorf("default int page: body = %s, want %s", body2, want)
	}

	// (c) site present → t244: serving.production_data_sync($1=cid), filter $2,
	//     LIMIT $3 OFFSET $4, offset (3-1)*50 = 100.
	req3 := httptest.NewRequest("GET", "/ext/montebello/data-sync?site=abc&page=3&limit=50", nil)
	req3.Header.Set("x-api-key", montebelloKey)
	serveShim(sh, reader, mbKeys(), montebelloOwner, req3)
	if !strings.Contains(gotSQL, "serving.production_data_sync($1) where site = UPPER($2) limit $3 offset $4") {
		t.Errorf("site SQL wrong: %s", gotSQL)
	}
	if len(gotArgs) != 4 || gotArgs[0] != montebelloOwner || gotArgs[1] != "abc" || gotArgs[2] != 50 || gotArgs[3] != 100 {
		t.Errorf("site args = %v, want [%d abc 50 100]", gotArgs, montebelloOwner)
	}
}

// TestMontebelloDataSyncErrorMatrix — header x-api-key contract (data-sync uses
// req.header('x-api-key'), the default membrane): missing → 400
// "x-api-key is required!", wrong-owner / unknown → 401 "Unauthorized access",
// and no read happens on rejection.
func TestMontebelloDataSyncErrorMatrix(t *testing.T) {
	sh := shimByPath(t, "/ext/montebello/data-sync")
	reader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
		return externalRows{cols: []string{"site"}, rows: nil}, nil
	}}
	cases := []struct {
		name      string
		setHeader bool
		key       string
		wantCode  int
		wantBody  string
		wantRead  bool
	}{
		{"missing header → 400", false, "", http.StatusBadRequest, "x-api-key is required!", false},
		{"wrong tenant → 401", true, incoplastKey, http.StatusUnauthorized, "Unauthorized access", false},
		{"unknown key → 401", true, "no-such", http.StatusUnauthorized, "Unauthorized access", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reader.called = 0
			req := httptest.NewRequest("GET", "/ext/montebello/data-sync", nil)
			if c.setHeader {
				req.Header.Set("x-api-key", c.key)
			}
			status, ct, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)
			if status != c.wantCode || body != c.wantBody || ct != "text/html; charset=utf-8" {
				t.Errorf("got (%d,%q,%q); want (%d,text/html; charset=utf-8,%q)", status, ct, body, c.wantCode, c.wantBody)
			}
			if (reader.called > 0) != c.wantRead {
				t.Errorf("reader called=%d, wantRead=%v", reader.called, c.wantRead)
			}
		})
	}
}

// ── Montebello events — {newData} + moment[Z] ────────────────────────────────

// TestMontebelloEventsGoldenShape pins `{newData}` with the moment[Z] VALUE
// adapter on ts_event/ts_end/last_update (second precision, literal Z), AND the
// back4 `if (item.ts_end)` guard: a NULL ts_end must serialize as `null`, not a
// reformatted zero time.
func TestMontebelloEventsGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/ext/montebello/events")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		// t244: serving.downtime_sync($1=cid) — the tenant is now an explicit param.
		if !strings.Contains(sql, "serving.downtime_sync($1)") {
			t.Errorf("expected serving.downtime_sync, got %s", sql)
		}
		if len(args) < 1 || args[0] != montebelloOwner {
			t.Errorf("serving.downtime_sync must bind $1 = cid (%d); got %v", montebelloOwner, args)
		}
		return externalRows{
			// pack_id is id_equipment_event::bigint (serving.downtime_sync)
			// → node-pg string "88"/"89", NOT a number. duration (int4) would stay a
			// number but isn't projected by this envelope.
			cols: []string{"nm_site", "nm_equipment", "ts_event", "ts_end", "pack_id", "last_update"},
			rows: [][]any{
				{"MONTEBELLO-01", "Linha 3 <A&B>", tsUTC(6, 0, 0), tsUTC(6, 5, 30), "88", tsUTC(6, 6, 0)},
				{"MONTEBELLO-01", "Linha 4", tsUTC(7, 0, 0), nil, "89", tsUTC(7, 1, 0)}, // NULL ts_end → null
			},
		}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/montebello/events?api_key="+montebelloKey, nil)
	status, ct, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)
	if status != http.StatusOK || ct != "application/json; charset=utf-8" {
		t.Errorf("status/ct = %d/%q, want 200/application/json; charset=utf-8", status, ct)
	}
	compareGolden(t, "montebello", "events", body)
}

// TestMontebelloEventsErrorMatrix — the api_key QUERY-param contract: missing OR
// the literal "undefined" → 400 "api_key is required!"; wrong-owner / unknown →
// 401 "Not authorized!" (the PINNED reject body, distinct from data-sync's).
func TestMontebelloEventsErrorMatrix(t *testing.T) {
	sh := shimByPath(t, "/ext/montebello/events")
	reader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
		t.Fatal("reader ran on a rejected request — no read must happen before auth passes")
		return externalRows{}, nil
	}}
	cases := []struct {
		name     string
		query    string
		wantCode int
		wantBody string
	}{
		{"missing api_key → 400", "", http.StatusBadRequest, "api_key is required!"},
		{"literal undefined → 400", "?api_key=undefined", http.StatusBadRequest, "api_key is required!"},
		{"wrong tenant → 401", "?api_key=" + incoplastKey, http.StatusUnauthorized, "Not authorized!"},
		{"unknown key → 401", "?api_key=nope", http.StatusUnauthorized, "Not authorized!"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/ext/montebello/events"+c.query, nil)
			status, ct, body := serveShim(sh, reader, mbKeys(), montebelloOwner, req)
			if status != c.wantCode || body != c.wantBody || ct != "text/html; charset=utf-8" {
				t.Errorf("got (%d,%q,%q); want (%d,text/html; charset=utf-8,%q)", status, ct, body, c.wantCode, c.wantBody)
			}
		})
	}
}

// ── Incoplast events — {newData} + moment[Z] + $1=cid fence ───────────────────

// TestIncoplastEventsGoldenShape pins `{newData}` + moment[Z], AND asserts the
// read is fenced by $1 = the injected customer_id (back4's id_enterprise → cid).
func TestIncoplastEventsGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/ext/incoplast/events")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		if len(args) < 1 || args[0] != incoplastOwner {
			t.Errorf("events_incoplast must bind $1 = customer_id (%d); got args %v", incoplastOwner, args)
		}
		return externalRows{
			// id_order is int4 → number; pack_id is id_equipment_event::bigint →
			// node-pg string "1234"; custom_field is JSONB → emitted as an OBJECT in
			// node-pg's stored key order (rawJSON, the reader's reserialized form —
			// this is a REAL production_orders.custom_field shape). duration (int4) is
			// not in this envelope.
			cols: []string{"id_order", "nm_site", "nm_equipment", "cd_shift", "ts_event", "ts_end", "pack_id", "custom_field", "packml_topic", "last_update"},
			rows: [][]any{{5501, "INCO-SITE", "Extrusora 2", "T1", tsUTC(6, 0, 0), tsUTC(6, 10, 0), "1234",
				rawJSON([]byte(`{"STATUS":1,"id_order":357226,"priority":10,"cd_client":34407,"scrap_factor":44.32910965352669,"PRODUCTION_STEP":62,"VERSION_PRODUCT":"9"}`)),
				"spBv1.0/inco/DDATA/EX2", tsUTC(6, 11, 0)}},
		}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/incoplast/events?api_key="+incoplastKey, nil)
	status, ct, body := serveShim(sh, reader, mbKeys(), incoplastOwner, req)
	if status != http.StatusOK || ct != "application/json; charset=utf-8" {
		t.Errorf("status/ct = %d/%q", status, ct)
	}
	compareGolden(t, "incoplast", "events", body)
}

// TestIncoplastEventsWrongTenantLeaksNothing is the owner-binding isolation gate:
// the ACL hardens back4 (which had NO reject here) so a stranger key 401s WITHOUT
// touching the read. The reject body is CHOSEN family-convention ("Unauthorized
// access"), flagged for §3d — see queryAPIKeyAuth.
func TestIncoplastEventsWrongTenantLeaksNothing(t *testing.T) {
	sh := shimByPath(t, "/ext/incoplast/events")
	reader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
		t.Fatal("reader ran for a wrong-tenant request — owner binding must fence BEFORE any read")
		return externalRows{}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/incoplast/events?api_key="+strangerKey, nil)
	status, ct, body := serveShim(sh, reader, mbKeys(), incoplastOwner, req)
	if status != http.StatusUnauthorized || body != "Unauthorized access" || ct != "text/html; charset=utf-8" {
		t.Errorf("wrong tenant: got (%d,%q,%q); want (401,text/html; charset=utf-8,\"Unauthorized access\")", status, ct, body)
	}
}

// ── Incoplast jobs — {jobs_filtered} + moment[Z] ─────────────────────────────

// TestIncoplastJobsGoldenShape pins the frozen `{jobs_filtered}` envelope (NOTE:
// the key is jobs_filtered, pinned from getjobsIncoplast — NOT {newData}) with
// the moment[Z] adapter on ts_start/ts_end/last_update, fenced by $1 = cid.
func TestIncoplastJobsGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/ext/incoplast/jobs")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		if len(args) < 1 || args[0] != incoplastOwner {
			t.Errorf("jobs_incoplast must bind $1 = customer_id (%d); got args %v", incoplastOwner, args)
		}
		return externalRows{
			// id_production_order is bigint → node-pg string "9001". net_production/
			// gross_production are DOUBLE PRECISION → JSON numbers (float8 matches
			// both drivers, no stringify): net_production 1234.5 stays unquoted here,
			// proving the numeric fix is scoped to numeric/int8 and does NOT touch
			// float8. custom_field is JSONB → an OBJECT in node-pg's stored key order.
			cols: []string{"id_production_order", "id_order", "net_production", "gross_production", "ts_start", "ts_end", "id_equipment", "status", "topic", "custom_field", "last_update"},
			rows: [][]any{{"9001", "OP-778", 1234.5, 1300.0, tsUTC(6, 0, 0), tsUTC(14, 0, 0), 42, 3, "spBv1.0/inco/DDATA/EX2",
				rawJSON([]byte(`{"STATUS":1,"id_order":356337,"priority":10,"cd_client":542113,"scrap_factor":20.895905129091858,"PRODUCTION_STEP":62,"VERSION_PRODUCT":"5"}`)),
				tsUTC(14, 0, 5)}},
		}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/incoplast/jobs?api_key="+incoplastKey, nil)
	status, ct, body := serveShim(sh, reader, mbKeys(), incoplastOwner, req)
	if status != http.StatusOK || ct != "application/json; charset=utf-8" {
		t.Errorf("status/ct = %d/%q", status, ct)
	}
	compareGolden(t, "incoplast", "jobs", body)
}

// TestIncoplastJobsDefaultsBinding pins back4's defaults + positional binding
// when ts_start/limit are absent: $1 = cid, $2 = ts_start (default present),
// $3 = limit 100. The default ts_start VALUE is time-dependent, so we assert its
// shape (YYYY-MM-DD HH:MM:SS) not an exact instant.
func TestIncoplastJobsDefaultsBinding(t *testing.T) {
	sh := shimByPath(t, "/ext/incoplast/jobs")
	var gotArgs []any
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		gotArgs = args
		return externalRows{cols: []string{"id_order"}, rows: nil}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/incoplast/jobs?api_key="+incoplastKey, nil)
	serveShim(sh, reader, mbKeys(), incoplastOwner, req)
	if len(gotArgs) != 3 {
		t.Fatalf("args = %v, want 3", gotArgs)
	}
	if gotArgs[0] != incoplastOwner {
		t.Errorf("$1 = %v, want cid %d", gotArgs[0], incoplastOwner)
	}
	if gotArgs[2] != 100 {
		t.Errorf("$3 (limit) = %v, want default 100", gotArgs[2])
	}
	ts, ok := gotArgs[1].(string)
	if !ok || len(ts) != len("2006-01-02 15:04:05") {
		t.Errorf("$2 (ts_start) = %v, want default 'YYYY-MM-DD HH:MM:SS'", gotArgs[1])
	}
}

// ── The moment[Z] value adapter (unit) ───────────────────────────────────────

// TestMomentZFormat locks the adapter itself: UTC, second precision, LITERAL
// trailing Z, NO milliseconds — distinct from the default toISOString `.000Z`.
func TestMomentZFormat(t *testing.T) {
	got := momentZFormat(time.Date(2026, 7, 18, 6, 5, 30, 123456789, time.UTC))
	if want := "2026-07-18T06:05:30Z"; got != want {
		t.Errorf("momentZFormat = %q, want %q (second precision, literal Z, no millis)", got, want)
	}
	// A non-UTC input is normalized to UTC (moment(...).utc()).
	loc := time.FixedZone("BRT", -3*3600)
	got2 := momentZFormat(time.Date(2026, 7, 18, 3, 0, 0, 0, loc)) // 03:00 -03:00 == 06:00Z
	if want := "2026-07-18T06:00:00Z"; got2 != want {
		t.Errorf("momentZFormat(non-UTC) = %q, want %q", got2, want)
	}
}

// ── Drift gate: the frozen Montebello/Incoplast objects are carried in ────────

// TestMontebelloIncoplastBackingObjectsAreDriftGated proves the generic serving.*
// functions (with their arity) and the guard relations all land in the
// contract-drift dump as external objects, so a dropped/renamed/re-signatured prod
// object blocks the flip fail-closed instead of 500ing a contract. t244
// enterprise-06/13 parameterization repointed data-sync and events off the frozen
// ent-6 objects (v_piot_production_data_sync_cust6 / get_downtime_sync_enterprsie_06)
// onto serving.production_data_sync($1) / serving.downtime_sync($1) — the arity 1 on
// each is the new load-bearing assertion (the tenant is now an explicit param).
func TestMontebelloIncoplastBackingObjectsAreDriftGated(t *testing.T) {
	objs, err := extractContract()
	if err != nil {
		t.Fatalf("extractContract: %v", err)
	}
	type key struct {
		kind string
		name string
	}
	want := map[key]bool{
		{"function", "serving.production_data_sync"}: false,
		{"function", "serving.downtime_sync"}:        false,
		{"relation", "equipment_events"}:             false,
		{"relation", "equipment_events_man"}:         false,
		{"relation", "production_orders"}:            false,
		{"relation", "packml_register"}:              false,
	}
	wantArgc := map[string]int{
		"serving.production_data_sync": 1,
		"serving.downtime_sync":        1,
	}
	for _, o := range objs {
		if o.Source != "external" {
			continue
		}
		k := key{o.Kind, o.Name}
		if _, tracked := want[k]; tracked {
			want[k] = true
			if o.Kind == "function" {
				if exp, ok := wantArgc[o.Name]; ok && o.ArgC != exp {
					t.Errorf("%s argc = %d, want %d", o.Name, o.ArgC, exp)
				}
			}
		}
		// The legacy frozen ent-6 objects must be GONE after the repoint.
		if o.Name == "v_piot_production_data_sync_cust6" || o.Name == "get_downtime_sync_enterprsie_06" {
			t.Errorf("legacy frozen object %q still referenced by an external shim after the t244 repoint", o.Name)
		}
	}
	for k, found := range want {
		if !found {
			t.Errorf("generic external %s %q not present in the drift-gate contract dump", k.kind, k.name)
		}
	}
}
