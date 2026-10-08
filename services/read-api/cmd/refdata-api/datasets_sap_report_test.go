package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// ── SAP shift report (Neopac) — front4 port of the legacy SAP report page ──
//
// The legacy page shipped an enterprise api_key in the browser and back4 gated on
// a hard-coded `id_enterprise != 13`. These tests pin the replacement's three
// properties DB-free: the tenant is the injected $1 (never the body, never a
// literal), the line is the ownership-guarded $2, and SAP data is opt-in per
// tenant via the report family (not by enterprise id).

var sapReportDatasets = []string{"sap-report-lines", "sap-report"}

func TestSapReportDatasetsAreTenantFencedAndConfigGated(t *testing.T) {
	for _, name := range sapReportDatasets {
		ds, ok := datasets[name]
		if !ok {
			t.Fatalf("SAP report dataset %q missing from the registry", name)
		}
		if len(ds.params) == 0 || ds.params[0].kind != pEnterprise {
			t.Errorf("%s: params[0] must be pEnterprise ($1)", name)
		}
		if strings.Contains(ds.sql, "api_key") {
			t.Errorf("%s: SQL references api_key — the tenancy secret must never transit this API", name)
		}
		// The back4 gate was `id_enterprise != 13`; no enterprise literal may survive.
		for _, lit := range []string{"= 13", "=13", "!= 13", "<> 13", "neopac", "NEOPAC"} {
			if strings.Contains(ds.sql, lit) {
				t.Errorf("%s: SQL carries the legacy tenant literal %q — gate on report config, not an id", name, lit)
			}
		}
		// Opt-in gate: only tenants whose report family is sap_de get rows.
		if !strings.Contains(ds.sql, "serving.report_config($1)->>'family' = 'sap_de'") {
			t.Errorf("%s: SQL must gate on the tenant's report family (sap_de)", name)
		}
		if ds.windowed {
			t.Errorf("%s: must not be windowed (sap_site_report owns its fixed window)", name)
		}
	}
}

func TestSapReportBindsTenantThenOwnedLine(t *testing.T) {
	ds := datasets["sap-report"]
	if len(ds.params) != 2 || ds.params[1].kind != pEquipmentID || ds.params[1].name != "equipment" {
		t.Fatalf("sap-report params must be [pEnterprise, equipment]; got %+v", ds.params)
	}
	// The line ($2) must be ownership-guarded by the tenant ($1), and the PO join
	// must be tenant-fenced too (id_order is only unique per enterprise).
	for _, frag := range []string{
		"serving.sap_site_report($1, $2)",
		"e.id_equipment = $2 AND e.id_enterprise = $1",
		"po.id_enterprise = $1 AND po.id_order = r.job",
		"AS order_number", // ADR-0062: the client PO number travels with the integer
	} {
		if !strings.Contains(ds.sql, frag) {
			t.Errorf("sap-report SQL missing %q:\n%s", frag, ds.sql)
		}
	}
	if strings.Contains(ds.sql, "SELECT *") || strings.Contains(ds.sql, "r.*") {
		t.Errorf("sap-report must be projection-shaped (ADR-0027 rule #2), not SELECT *")
	}
}

func TestSapReportCompileDisjointAcrossTenants(t *testing.T) {
	const tenantA, tenantB = 13, 3
	req := datasetReq{Dataset: "sap-report", Filters: map[string]json.RawMessage{"equipment": json.RawMessage(`412`)}}
	aSQL, aArgs, aErr := compileDataset(req, tenantA, callerRole{})
	bSQL, bArgs, bErr := compileDataset(req, tenantB, callerRole{})
	if aErr != nil || bErr != nil {
		t.Fatalf("compile err a=%v b=%v", aErr, bErr)
	}
	if aSQL != bSQL {
		t.Errorf("compiled SQL differs across tenants — customerID must be a bound arg, not text")
	}
	if aArgs[0] != tenantA || bArgs[0] != tenantB {
		t.Errorf("$1 must be the caller's tenant; got %v / %v", aArgs[0], bArgs[0])
	}
	if aArgs[1] != 412 || bArgs[1] != 412 {
		t.Errorf("$2 must be the requested line for both tenants; got %v / %v", aArgs[1], bArgs[1])
	}
}

func TestSapReportRejectsMissingLineAndClientTenant(t *testing.T) {
	// No line ⇒ fail closed (no tenant-wide SAP dump).
	if _, _, err := compileDataset(datasetReq{Dataset: "sap-report"}, 13, callerRole{}); err == nil {
		t.Error("sap-report without filters.equipment must be rejected")
	}
	// A client cannot steer the tenant through the body.
	for _, key := range []string{"enterprise", "id_enterprise", "customer_id"} {
		req := datasetReq{Dataset: "sap-report", Filters: map[string]json.RawMessage{
			"equipment": json.RawMessage(`412`), key: json.RawMessage(`13`)}}
		if _, _, err := compileDataset(req, 3, callerRole{}); err == nil {
			t.Errorf("sap-report accepted a client-supplied %q filter", key)
		}
	}
	// The lines list takes no client filters at all.
	req := datasetReq{Dataset: "sap-report-lines", Filters: map[string]json.RawMessage{"equipment": json.RawMessage(`1`)}}
	if _, _, err := compileDataset(req, 13, callerRole{}); err == nil {
		t.Error("sap-report-lines must not accept client filters")
	}
	// A window is meaningless here (fixed window in the fn) and must be refused.
	if _, _, err := compileDataset(datasetReq{Dataset: "sap-report-lines", Window: &dsWindow{}}, 13, callerRole{}); err == nil {
		t.Error("sap-report-lines must refuse a window")
	}
}
