package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ── task #54 / ADR-0031 Workstream A: the 3 net-new back4-retirement datasets ──
//
// oee-by-month, suzano-analogs, report-downtimes are the READ→refdata endpoints
// whose back4 originals either took a bare id with NO tenant fence (oee-by-month),
// or HARDCODED a client-specific id set (suzano-analogs: id_equipment IN (404,411);
// report-downtimes: id_enterprise = 37). refdata exists to remove exactly that
// anti-pattern: every one binds the injected customer_id at $1 and carries no
// client literal. These tests pin that per-dataset, plus the pDate param kind.

// workstreamADatasets is the exact set this task adds — a pinned list so a future
// rename/drop is a visible failure, not a silent coverage hole (same discipline
// as TestFront4MigrationDatasetsAreClassifiedTenantSafe).
var workstreamADatasets = []string{"oee-by-month", "suzano-analogs", "report-downtimes"}

func TestWorkstreamADatasetsAreTenantFenced(t *testing.T) {
	for _, name := range workstreamADatasets {
		ds, ok := datasets[name]
		if !ok {
			t.Errorf("workstream-A dataset %q missing from the registry", name)
			continue
		}
		// params[0] == pEnterprise ($1) is the structural tenancy guard.
		if len(ds.params) == 0 || ds.params[0].kind != pEnterprise {
			t.Errorf("dataset %q: params[0] must be pEnterprise ($1)", name)
		}
		if !strings.Contains(ds.sql, "$1") {
			t.Errorf("dataset %q: SQL never binds the injected tenant $1:\n%s", name, ds.sql)
		}
		// No client literal may survive from the back4 originals — the whole point
		// of the rewrite is that 404/411 and 37 became $1-fenced filters.
		for _, literal := range []string{"404", "411", "id_enterprise = 37", "id_enterprise=37"} {
			if strings.Contains(ds.sql, literal) {
				t.Errorf("dataset %q: SQL still carries the back4 hardcoded literal %q — it must be a $1-fenced filter", name, literal)
			}
		}
		if strings.Contains(ds.sql, "api_key") {
			t.Errorf("dataset %q: SQL references api_key — the tenancy secret must never transit this API", name)
		}
	}
}

// Cross-tenant disjointness, proven DB-free: the compiled SQL must be BYTE-
// IDENTICAL across two tenants (customerID is a bound arg, never SQL text), and
// only args[0] differs. Two tenants asking the same dataset get the same query
// with a different $1 — so tenant A can never see tenant B's rows.
func TestWorkstreamADatasetsCompileDisjointAcrossTenants(t *testing.T) {
	const tenantA, tenantB = 3, 4
	// A representative valid body per dataset (required filters supplied).
	bodies := map[string]map[string]json.RawMessage{
		"oee-by-month":     {"equipment": json.RawMessage(`7`), "month": json.RawMessage(`"2026-03-15"`)},
		"suzano-analogs":   {"equipments": json.RawMessage(`[404,411]`), "from": json.RawMessage(`"2026-03-01"`)},
		"report-downtimes": {"datetime": json.RawMessage(`"2026-03-15 08:00:00"`)},
	}
	for _, name := range workstreamADatasets {
		req := datasetReq{Dataset: name, Filters: bodies[name]}
		aSQL, aArgs, aErr := compileDataset(req, tenantA, callerRole{})
		bSQL, bArgs, bErr := compileDataset(req, tenantB, callerRole{})
		if aErr != nil || bErr != nil {
			t.Fatalf("%s: compile err a=%v b=%v", name, aErr, bErr)
		}
		if aSQL != bSQL {
			t.Errorf("%s: compiled SQL differs across tenants — customerID must be a bound arg, not text", name)
		}
		if aArgs[0] != tenantA || bArgs[0] != tenantB {
			t.Errorf("%s: $1 must be the caller's tenant; got %v / %v", name, aArgs[0], bArgs[0])
		}
		if len(aArgs) != len(bArgs) {
			t.Fatalf("%s: arg count differs across tenants", name)
		}
		// Every arg beyond $1 (the client filters) must be identical — only the
		// injected tenant moves.
		for i := 1; i < len(aArgs); i++ {
			if aArgs[i] != bArgs[i] {
				t.Errorf("%s: arg $%d differs across tenants (%v vs %v) — only $1 may move", name, i+1, aArgs[i], bArgs[i])
			}
		}
	}
}

// oee-by-month binds tenant $1, the ownership-guarded equipment $2, and the month
// scalar $3 (pDate). The month is bound as a time.Time (never interpolated).
func TestOeeByMonthBindsTenantEquipmentAndMonth(t *testing.T) {
	// Missing required filters must fail closed.
	for _, f := range []map[string]json.RawMessage{
		nil,                                 // no equipment, no month
		{"equipment": json.RawMessage(`7`)}, // missing month
		{"month": json.RawMessage(`"2026-03-15"`)},                                    // missing equipment
		{"equipment": json.RawMessage(`7`), "month": json.RawMessage(`"not-a-date"`)}, // bad month
	} {
		if _, _, err := compileDataset(datasetReq{Dataset: "oee-by-month", Filters: f}, 42, callerRole{}); err == nil {
			t.Errorf("oee-by-month compiled with invalid filters %v", f)
		}
	}
	sql, args, err := compileDataset(datasetReq{Dataset: "oee-by-month",
		Filters: map[string]json.RawMessage{"equipment": json.RawMessage(`7`), "month": json.RawMessage(`"2026-03-15"`)}}, 42, callerRole{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "e.id_enterprise = $1") || !strings.Contains(sql, "e.id_equipment = $2") || !strings.Contains(sql, "$3::date") {
		t.Errorf("oee-by-month SQL missing tenant/equipment/month bindings: %s", sql)
	}
	if !strings.Contains(sql, "LIMIT 10000") {
		t.Errorf("oee-by-month missing row cap: %s", sql)
	}
	if len(args) != 3 || args[0] != 42 || args[1] != 7 {
		t.Fatalf("oee-by-month args = %v; want [42 7 <time>]", args)
	}
	tv, ok := args[2].(time.Time)
	if !ok || !tv.Equal(time.Date(2026, 3, 15, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("oee-by-month month must bind as time.Time 2026-03-15; got %v (%T)", args[2], args[2])
	}
}

// suzano-analogs binds tenant $1, the equipments id-filter $2 (cardinality 0 =
// all my equipment — the 404/411 literal is gone), and the from-instant $3.
func TestSuzanoAnalogsFencesEquipmentSetAndFrom(t *testing.T) {
	if _, _, err := compileDataset(datasetReq{Dataset: "suzano-analogs"}, 42, callerRole{}); err == nil {
		t.Error("suzano-analogs compiled without the required `from` filter")
	}
	// No equipments filter ⇒ cardinality-0 int array ⇒ all the tenant's equipment.
	sql, args, err := compileDataset(datasetReq{Dataset: "suzano-analogs",
		Filters: map[string]json.RawMessage{"from": json.RawMessage(`"2026-03-01"`)}}, 42, callerRole{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sql, "id_enterprise = $1") || !strings.Contains(sql, "$2::int[]") || !strings.Contains(sql, "$3::timestamp") {
		t.Errorf("suzano-analogs SQL missing bindings: %s", sql)
	}
	if !strings.Contains(sql, `analogs->'DATA' @> '[{"type": "PPM"}]'`) {
		t.Errorf("suzano-analogs must preserve the DATA-scoped PPM predicate: %s", sql)
	}
	if args[0] != 42 || args[1] != "{}" {
		t.Errorf("suzano-analogs empty equipments must bind {} at $2; got %v", args)
	}
	// With an explicit set, the fence carries it (still $1-scoped).
	_, args2, _ := compileDataset(datasetReq{Dataset: "suzano-analogs",
		Filters: map[string]json.RawMessage{"equipments": json.RawMessage(`[404,411]`), "from": json.RawMessage(`"2026-03-01"`)}}, 42, callerRole{})
	if args2[1] != "{404,411}" {
		t.Errorf("suzano-analogs equipments filter must bind the pg array; got %v", args2[1])
	}
}

// report-downtimes reads the dba-owned v_report_downtimes view, fenced to the
// tenant $1 and bucketed by the datetime $2 (pDate). The hardcoded id_enterprise
// = 37 is gone.
func TestReportDowntimesFencesTenantAndDatetime(t *testing.T) {
	if _, _, err := compileDataset(datasetReq{Dataset: "report-downtimes"}, 42, callerRole{}); err == nil {
		t.Error("report-downtimes compiled without the required `datetime` filter")
	}
	// pDate accepts both a space-separated datetime and RFC3339.
	for _, dt := range []string{`"2026-03-15 08:00:00"`, `"2026-03-15T08:00:00Z"`, `"2026-03-15"`} {
		sql, args, err := compileDataset(datasetReq{Dataset: "report-downtimes",
			Filters: map[string]json.RawMessage{"datetime": json.RawMessage(dt)}}, 42, callerRole{})
		if err != nil {
			t.Fatalf("report-downtimes datetime %s: %v", dt, err)
		}
		if !strings.Contains(sql, "FROM v_report_downtimes") ||
			!strings.Contains(sql, "id_enterprise = $1") ||
			!strings.Contains(sql, "date_trunc('hour', $2::timestamp)") {
			t.Errorf("report-downtimes SQL missing view/tenant/bucket bindings: %s", sql)
		}
		if len(args) != 2 || args[0] != 42 {
			t.Fatalf("report-downtimes args = %v; want [42 <time>]", args)
		}
		if _, ok := args[1].(time.Time); !ok {
			t.Errorf("report-downtimes datetime must bind as time.Time; got %T", args[1])
		}
	}
}

// pDate is a CLIENT filter, never the tenant axis: every pDateScalar param has a
// filter name and is never params[0]. This is the analogue of the pUserRole
// server-derived guard, inverted — pDate is client-settable, so it must never be
// able to sit where $1 (the injected tenant) sits.
func TestPDateIsClientFilterNeverTenantAxis(t *testing.T) {
	for name, ds := range datasets {
		for i, p := range ds.params {
			if p.kind != pDateScalar {
				continue
			}
			if p.name == "" {
				t.Errorf("dataset %q: a pDate param must have a filter name (it is a client filter)", name)
			}
			if i == 0 {
				t.Errorf("dataset %q: pDate must never be params[0] — $1 is the injected tenant", name)
			}
		}
	}
}

// TestParseDateFilter pins the layout allowlist directly: valid layouts parse,
// anything else (and any SQL-ish text) is rejected — the value can never carry
// arbitrary SQL because it is bound as a time.Time, never interpolated.
func TestParseDateFilter(t *testing.T) {
	good := []string{"2026-03-15", "2026-03-15 08:00:00", "2026-03-15T08:00:00Z"}
	for _, s := range good {
		if _, err := parseDateFilter(s); err != nil {
			t.Errorf("parseDateFilter(%q) errored: %v", s, err)
		}
	}
	bad := []string{"", "not-a-date", "2026/03/15", "2026-13-40", "'; DROP TABLE x --", "now()"}
	for _, s := range bad {
		if _, err := parseDateFilter(s); err == nil {
			t.Errorf("parseDateFilter(%q) accepted an invalid value", s)
		}
	}
}

// The auth gate fronts the new datasets exactly like every other read: a POST
// /v1/query with no credential 401s WITHOUT reaching the handler — compileDataset
// is never reached unauthenticated, so no dataset (new ones included) can serve a
// tenant-less request. (Dataset-agnostic by construction; asserted here for the
// #54 datasets' request path.)
func TestWorkstreamAReadsRequireAuth(t *testing.T) {
	mw := authMiddleware(map[string]int{"good-key": 7}, infraExemptSet(), nil,
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			t.Error("handler reached without a credential — the read must fail closed")
		}))
	for _, name := range workstreamADatasets {
		body, _ := json.Marshal(datasetReq{Dataset: name})
		req := httptest.NewRequest("POST", "/v1/query", strings.NewReader(string(body)))
		rr := httptest.NewRecorder()
		mw.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Errorf("%s: unauthenticated /v1/query code=%d, want 401", name, rr.Code)
		}
	}
}
