package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// ADR-0064: on a production mirror tenant every scan is refused before the store is touched.
func TestPostScan_ProdMirrorTenantIs403(t *testing.T) {
	srv := &scanServer{mirror: map[int]bool{testEnt: true}} // nil store: a write attempt would panic
	body := `{"scan_uuid":"u1","id_production_order":1,"id_equipment":1,"raw_barcode":"x"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/scans", strings.NewReader(body))
	req = req.WithContext(withEnterpriseID(req.Context(), testEnt))
	rec := httptest.NewRecorder()
	srv.handlePostScan(rec, req)
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "MIRROR_TENANT_WRITE_BLOCKED") {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
}

func TestParseProdMirror(t *testing.T) {
	m, err := parseProdMirror(" 5 ,7")
	if err != nil || !m[5] || !m[7] || len(m) != 2 {
		t.Fatalf("%v %v", m, err)
	}
	if m, _ := parseProdMirror(""); len(m) != 0 {
		t.Fatal("empty = no mirror")
	}
	if _, err := parseProdMirror("5,x"); err == nil {
		t.Fatal("a typo must fail the boot")
	}
}
