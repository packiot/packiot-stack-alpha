package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// external_golden_test.go — ADR-0031 §3c: the GOLDEN-FIXTURE HARNESS.
//
// This is the RETIREMENT GATE for a Family-A external shim. A shim may only cut
// over when (a) this golden test is green AND (b) the external owner signs off
// (§3d). The test drives the real registered shim runner with a fake row source
// (no DB) and asserts the response is BYTE-IDENTICAL to the frozen back4 shape
// captured under testdata/external/<consumer>/<endpoint>.golden.json — the exact
// bytes `SapReportControllerNeopac` / `DataSyncControllerNeopac` emit via Express
// res.json (envelope keys, key ORDER, pagination int types, no HTML-escaping, no
// trailing newline). A field renamed, a number stringified differently, a key
// re-ordered, or a timestamp format drift FAILS THE BUILD.
//
// SCOPE OF THE PIN (honest boundary — see external.go / the PR report):
// the ENVELOPE and the column-ordered row shape are pinned exactly from source.
// The fixture rows use value types whose Go↔node-postgres JSON serialization is
// KNOWN to match (string, int, bool, and time.Time→ISO-Z). Postgres numeric/
// decimal is DELIBERATELY absent: node-pg returns numeric as a STRING and the
// column typing is a live-view property unreadable from the controller source —
// that parity is the §3c step-3 SHADOW-DIFF item, gated before cutover, never
// asserted here as if it were pinned.

// discardLogger is a no-op slog logger for the handler under test.
func discardLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// scriptedReader is the injected fake row source: it answers each query() from a
// closure keyed on the SQL, so a shim's multi-step read (equipment resolve →
// view read) is scripted without a database.
type scriptedReader struct {
	fn     func(sql string, args []any) (externalRows, error)
	called int
}

func (s *scriptedReader) query(_ context.Context, sql string, args ...any) (externalRows, error) {
	s.called++
	return s.fn(sql, args)
}

func shimByPath(t *testing.T, path string) externalShim {
	t.Helper()
	for _, sh := range externalShims {
		if sh.path == path {
			return sh
		}
	}
	t.Fatalf("external shim %q is not registered", path)
	return externalShim{}
}

// serveShim drives one shim's handler and returns (status, contentType, body).
func serveShim(sh externalShim, reader externalReader, keys map[string]int, owner int, req *http.Request) (int, string, string) {
	h := makeExternalHandler(sh, reader, keys, owner, discardLogger())
	rr := httptest.NewRecorder()
	h(rr, req)
	res := rr.Result()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, res.Header.Get("Content-Type"), string(body)
}

const (
	neopacKey    = "neopac-sap-key"
	otherKey     = "montebello-key"
	neopacOwner  = 13 // stand-in for EXTERNAL_NEOPAC_CUSTOMER_ID (config, not a code literal)
	otherOwnerID = 6
)

func neopacKeys() map[string]int {
	return map[string]int{neopacKey: neopacOwner, otherKey: otherOwnerID}
}

func readGolden(t *testing.T, consumer, name string) string {
	t.Helper()
	p := filepath.Join("testdata", "external", consumer, name+".golden.json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read golden %s: %v", p, err)
	}
	return string(b)
}

// TestNeopacSapReportGoldenShape — the frozen `{data}` envelope, byte-identical.
func TestNeopacSapReportGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/ext/neopac/sap-report")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		if strings.Contains(sql, "FROM equipments") {
			// lineCode→id_equipment, fenced by $1 (the injected customer_id).
			if len(args) < 1 || args[0] != neopacOwner {
				t.Errorf("equipments lookup must bind $1 = customer_id; got args %v", args)
			}
			return externalRows{cols: []string{"id_equipment"}, rows: [][]any{{42}}}, nil
		}
		// The frozen v_13_site_deb_sap_report row (column order preserved). The
		// bezeichnung carries `<A&B>` + German chars to prove no HTML-escaping;
		// erstellt is a time.Time to prove the ISO-Z timestamp form.
		return externalRows{
			cols: []string{"id_equipment", "werk", "material", "menge_soll", "bezeichnung", "erstellt"},
			rows: [][]any{{42, "1300", "MAT-1", 1000, "Kübel groß <A&B>", time.Date(2026, 7, 18, 6, 0, 0, 0, time.UTC)}},
		}, nil
	}}

	req := httptest.NewRequest("GET", "/ext/neopac/sap-report?lineCode=L01", nil)
	req.Header.Set("x-api-key", neopacKey)
	status, ct, body := serveShim(sh, reader, neopacKeys(), neopacOwner, req)

	if status != http.StatusOK {
		t.Errorf("status = %d, want 200", status)
	}
	if ct != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want application/json; charset=utf-8", ct)
	}
	if want := readGolden(t, "neopac", "sap-report"); body != want {
		t.Errorf("sap-report body not byte-identical to frozen golden.\n got:  %s\n want: %s", body, want)
	}
}

// TestNeopacSapReportSyncGoldenShape — the frozen `{page,limit,results,data}`
// envelope, byte-identical: page/limit as ints, results = row count, data in
// column order, pagination echoed from the query.
func TestNeopacSapReportSyncGoldenShape(t *testing.T) {
	sh := shimByPath(t, "/ext/neopac/sap-report-sync")
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		return externalRows{
			cols: []string{"auftrag", "linie", "tag", "shicht", "shicht_nummer", "gestartet"},
			rows: [][]any{
				{"4711", "L01", "2026-07-18", "F", 1, time.Date(2026, 7, 18, 6, 0, 0, 0, time.UTC)},
				{"4712", "L02", "2026-07-18", "S", 2, time.Date(2026, 7, 18, 14, 0, 0, 0, time.UTC)},
			},
		}, nil
	}}

	req := httptest.NewRequest("GET", "/ext/neopac/sap-report-sync?page=2&limit=50", nil)
	req.Header.Set("x-api-key", neopacKey)
	status, ct, body := serveShim(sh, reader, neopacKeys(), neopacOwner, req)

	if status != http.StatusOK {
		t.Errorf("status = %d, want 200", status)
	}
	if ct != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want application/json; charset=utf-8", ct)
	}
	if want := readGolden(t, "neopac", "sap-report-sync"); body != want {
		t.Errorf("sap-report-sync body not byte-identical to frozen golden.\n got:  %s\n want: %s", body, want)
	}
}

// TestNeopacSapReportSyncPaginationSemantics pins back4's exact LIMIT/OFFSET +
// filter binding (offset = (page-1)*limit; defaults page=1 limit=1000; linie
// upper-cased; filters bound positionally before LIMIT/OFFSET).
func TestNeopacSapReportSyncPaginationSemantics(t *testing.T) {
	sh := shimByPath(t, "/ext/neopac/sap-report-sync")
	var gotSQL string
	var gotArgs []any
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		gotSQL, gotArgs = sql, args
		return externalRows{cols: []string{"auftrag"}, rows: nil}, nil // empty result
	}}

	req := httptest.NewRequest("GET", "/ext/neopac/sap-report-sync?page=3&limit=25&linie=l07&auftrag=999", nil)
	req.Header.Set("x-api-key", neopacKey)
	status, _, body := serveShim(sh, reader, neopacKeys(), neopacOwner, req)
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	// Empty result ⇒ results:0 and data:[] (never null).
	if want := `{"page":3,"limit":25,"results":0,"data":[]}`; body != want {
		t.Errorf("empty-result body = %s, want %s", body, want)
	}
	// auftrag=$1, linie=$2 (upper-cased), then LIMIT $3 OFFSET $4.
	if !strings.Contains(gotSQL, "auftrag = $1") || !strings.Contains(gotSQL, "linie = $2") ||
		!strings.Contains(gotSQL, "LIMIT $3 OFFSET $4") {
		t.Errorf("pagination SQL wrong: %s", gotSQL)
	}
	// args: [auftrag, LINIE(upper), limit=25, offset=(3-1)*25=50]
	wantArgs := []any{"999", "L07", 25, 50}
	if len(gotArgs) != len(wantArgs) {
		t.Fatalf("args = %v, want %v", gotArgs, wantArgs)
	}
	for i := range wantArgs {
		if gotArgs[i] != wantArgs[i] {
			t.Errorf("arg[%d] = %v (%T), want %v", i, gotArgs[i], gotArgs[i], wantArgs[i])
		}
	}
}

// TestNeopacSapReportErrorMatrix — the frozen error contract (byte-identical
// status + text/html body), across missing-key, wrong-tenant, unknown-key, and
// line-not-found. This is the anti-corruption discipline applied to the ERROR
// surface, not just the happy path.
func TestNeopacSapReportErrorMatrix(t *testing.T) {
	sh := shimByPath(t, "/ext/neopac/sap-report")
	// A reader that returns NO equipment (drives the 404) and records if it ran.
	reader := &scriptedReader{fn: func(sql string, args []any) (externalRows, error) {
		return externalRows{cols: []string{"id_equipment"}, rows: nil}, nil
	}}

	cases := []struct {
		name     string
		key      string // "" ⇒ header omitted
		setKey   bool
		wantCode int
		wantCT   string
		wantBody string
		wantRead bool // did the reader run? (isolation: a rejected caller reads nothing)
	}{
		{"missing key → 400", "", false, http.StatusBadRequest, "text/html; charset=utf-8", "x-api-key is required!", false},
		{"wrong tenant → 401", otherKey, true, http.StatusUnauthorized, "text/html; charset=utf-8", "Unauthorized access", false},
		{"unknown key → 401", "no-such-key", true, http.StatusUnauthorized, "text/html; charset=utf-8", "Unauthorized access", false},
		{"line not found → 404", neopacKey, true, http.StatusNotFound, "text/html; charset=utf-8", "Line code not found", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reader.called = 0
			req := httptest.NewRequest("GET", "/ext/neopac/sap-report?lineCode=NOPE", nil)
			if c.setKey {
				req.Header.Set("x-api-key", c.key)
			}
			status, ct, body := serveShim(sh, reader, neopacKeys(), neopacOwner, req)
			if status != c.wantCode || ct != c.wantCT || body != c.wantBody {
				t.Errorf("got (%d, %q, %q); want (%d, %q, %q)", status, ct, body, c.wantCode, c.wantCT, c.wantBody)
			}
			if (reader.called > 0) != c.wantRead {
				t.Errorf("reader called=%d, wantRead=%v — a rejected caller must read NO tenant data", reader.called, c.wantRead)
			}
		})
	}
}

// TestNeopacSapReportSyncWrongTenantLeaksNothing is the isolation gate for the
// frozen-view shim (no id_enterprise column to fence in SQL): a valid key bound
// to ANOTHER customer must 401 WITHOUT reading the customer-13 view.
func TestNeopacSapReportSyncWrongTenantLeaksNothing(t *testing.T) {
	sh := shimByPath(t, "/ext/neopac/sap-report-sync")
	reader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
		t.Fatal("reader was called for a wrong-tenant request — the owner binding must fence BEFORE any read")
		return externalRows{}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/neopac/sap-report-sync", nil)
	req.Header.Set("x-api-key", otherKey) // resolves to customer 6, not the bound 13
	status, ct, body := serveShim(sh, reader, neopacKeys(), neopacOwner, req)
	if status != http.StatusUnauthorized || body != "Unauthorized access" || ct != "text/html; charset=utf-8" {
		t.Errorf("wrong tenant: got (%d, %q, %q); want (401, text/html; charset=utf-8, \"Unauthorized access\")", status, ct, body)
	}
}

// TestExternalShimsDeclareOwnerBinding is the STATIC isolation gate for the
// external plane (the analogue of "params[0] == pEnterprise" for datasets):
// every external shim MUST declare an ownerEnv, so the frozen customer-scoped
// view can never be reached by an unbound caller. A shim added without one is a
// build failure here, not a silent cross-tenant hole.
func TestExternalShimsDeclareOwnerBinding(t *testing.T) {
	if len(externalShims) == 0 {
		t.Fatal("no external shims registered — the gate has nothing to guard")
	}
	seen := map[string]bool{}
	for _, sh := range externalShims {
		if sh.ownerEnv == "" {
			t.Errorf("external shim %q: missing ownerEnv — no owner binding means no tenant fence", sh.path)
		}
		if sh.run == nil {
			t.Errorf("external shim %q: nil run", sh.path)
		}
		if len(sh.backingViews)+len(sh.backingFunctions)+len(sh.guardRelations) == 0 {
			t.Errorf("external shim %q: declares no backing views/functions/guard relations — the drift gate can't verify the frozen prod object exists", sh.path)
		}
		if seen[sh.path] {
			t.Errorf("external shim path %q registered twice", sh.path)
		}
		seen[sh.path] = true
	}
}

// TestExternalShimOwnerUnsetFailsClosed: owner == 0 (env unset) ⇒ EVERY request
// 401s, even one with an otherwise-valid key. A mis-provisioned shim must fail
// closed, never serve another tenant's frozen view.
func TestExternalShimOwnerUnsetFailsClosed(t *testing.T) {
	sh := shimByPath(t, "/ext/neopac/sap-report-sync")
	reader := &scriptedReader{fn: func(string, []any) (externalRows, error) {
		t.Fatal("reader ran with owner unset — must fail closed")
		return externalRows{}, nil
	}}
	req := httptest.NewRequest("GET", "/ext/neopac/sap-report-sync", nil)
	req.Header.Set("x-api-key", neopacKey) // valid key, but owner=0 below
	status, _, body := serveShim(sh, reader, neopacKeys(), 0 /* owner unset */, req)
	if status != http.StatusUnauthorized || body != "Unauthorized access" {
		t.Errorf("owner unset: got (%d, %q); want 401 \"Unauthorized access\"", status, body)
	}
}

// TestExternalBackingViewsAreDriftGated proves the frozen external views are
// carried into the contract-drift extraction (existence-only), so a dropped/
// renamed prod view blocks the flip fail-closed rather than 500ing an external
// contract silently.
func TestExternalBackingViewsAreDriftGated(t *testing.T) {
	objs, err := extractContract()
	if err != nil {
		t.Fatalf("extractContract: %v", err)
	}
	want := map[string]bool{
		"v_13_site_deb_sap_report":           false,
		"v_sap_report_data_sync_customer_13": false,
	}
	for _, o := range objs {
		if o.Source == "external" {
			if _, tracked := want[o.Name]; tracked {
				want[o.Name] = true
			}
		}
	}
	for view, found := range want {
		if !found {
			t.Errorf("frozen external view %q not present in the drift-gate contract dump", view)
		}
	}
}
